import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sodium/sodium_sumo.dart';

import 'image_attachment.dart';
import 'models.dart';

class VaultCrypto {
  VaultCrypto(this.sodium);
  final SodiumSumo sodium;
  SecureKey? _key;
  String? vaultId;
  bool get unlocked => _key != null;
  static const memoryLimit = 64 * 1024 * 1024;
  static const operations = 3;

  static Future<VaultCrypto> initialize() async =>
      VaultCrypto(await SodiumSumoInit.init());

  Future<SecureKey> _derive(String password, Json descriptor) async {
    if (descriptor['algorithm'] != 'argon2id13' ||
        descriptor['memory'] != memoryLimit ||
        descriptor['operations'] != operations) {
      throw const FormatException('不支持的密码派生参数');
    }
    final salt = base64Decode(descriptor['salt'] as String);
    if (salt.length != 16) throw const FormatException('无效的密钥包');
    final bytes = await Isolate.run(() async {
      final s = await SodiumSumoInit.init();
      final derived = s.crypto.pwhash.callStr(
        outLen: 32,
        password: password,
        salt: salt,
        opsLimit: operations,
        memLimit: memoryLimit,
        alg: CryptoPwhashAlgorithm.argon2id13,
      );
      try {
        return derived.extractBytes();
      } finally {
        derived.dispose();
      }
    });
    try {
      return sodium.secureCopy(bytes);
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  Json _descriptor() => {
    'algorithm': 'argon2id13',
    'memory': memoryLimit,
    'operations': operations,
    'salt': base64Encode(sodium.randombytes.buf(16)),
  };

  Json _seal(Uint8List bytes, SecureKey key, String aad) {
    final nonce = sodium.randombytes.buf(24);
    final encrypted = sodium.crypto.aeadXChaCha20Poly1305IETF.encrypt(
      message: bytes,
      nonce: nonce,
      key: key,
      additionalData: Uint8List.fromList(utf8.encode(aad)),
    );
    return {'nonce': base64Encode(nonce), 'payload': base64Encode(encrypted)};
  }

  Uint8List _open(Json envelope, SecureKey key, String aad) {
    final nonce = base64Decode(envelope['nonce'] as String);
    final cipher = base64Decode(envelope['payload'] as String);
    if (nonce.length != 24 ||
        cipher.length < 16 ||
        cipher.length > 64 * 1024 * 1024) {
      throw const FormatException('密文格式不正确');
    }
    return sodium.crypto.aeadXChaCha20Poly1305IETF.decrypt(
      cipherText: cipher,
      nonce: nonce,
      key: key,
      additionalData: Uint8List.fromList(utf8.encode(aad)),
    );
  }

  Future<({Json envelope, String recoveryCode})> create(String password) async {
    if (password.length < 10) throw const FormatException('主密码至少需要 10 个字符');
    lock();
    final id = uuid.v4();
    final key = sodium.crypto.aeadXChaCha20Poly1305IETF.keygen();
    final recovery = sodium.secureRandom(32);
    final kdf = _descriptor();
    final wrapping = await _derive(password, kdf);
    try {
      final wrapped = key.runUnlockedSync(
        (bytes) => _seal(bytes, wrapping, 'xingji-key:1:$id:password'),
      );
      final recoveryWrapped = key.runUnlockedSync(
        (bytes) => _seal(bytes, recovery, 'xingji-key:1:$id:recovery'),
      );
      final recoveryCode = recovery.runUnlockedSync(
        (bytes) => 'XJ1.${base64UrlEncode(bytes).replaceAll('=', '')}',
      );
      _key = key;
      vaultId = id;
      final envelope = {
        'format': 1,
        'vault_id': id,
        'key_version': 1,
        'kdf': kdf,
        'password': wrapped,
        'recovery': recoveryWrapped,
      };
      return (envelope: _prove(envelope), recoveryCode: recoveryCode);
    } catch (_) {
      key.dispose();
      rethrow;
    } finally {
      wrapping.dispose();
      recovery.dispose();
    }
  }

  Future<void> unlock(
    Json envelope,
    String secret, {
    bool recovery = false,
  }) async {
    _validateEnvelope(envelope);
    final id = envelope['vault_id'] as String;
    SecureKey wrapper;
    if (recovery) {
      final normalized = secret.replaceAll(RegExp(r'\s'), '');
      if (!normalized.startsWith('XJ1.')) {
        throw const FormatException('恢复码格式不正确');
      }
      final raw = base64Url.decode(
        base64Url.normalize(normalized.substring(4)),
      );
      if (raw.length != 32) throw const FormatException('恢复码格式不正确');
      wrapper = sodium.secureCopy(raw);
      raw.fillRange(0, raw.length, 0);
    } else {
      wrapper = await _derive(
        secret,
        Map<String, dynamic>.from(envelope['kdf'] as Map),
      );
    }
    try {
      final kind = recovery ? 'recovery' : 'password';
      final raw = _open(
        Map<String, dynamic>.from(envelope[kind] as Map),
        wrapper,
        'xingji-key:1:$id:$kind',
      );
      try {
        if (raw.length != 32) throw const FormatException('资料库密钥格式错误');
        lock();
        _key = sodium.secureCopy(raw);
        vaultId = id;
        try {
          verifyEnvelope(envelope);
        } catch (_) {
          lock();
          rethrow;
        }
      } finally {
        raw.fillRange(0, raw.length, 0);
      }
    } finally {
      wrapper.dispose();
    }
  }

  void _validateEnvelope(Json envelope) {
    if (envelope['format'] != 1 ||
        envelope['key_version'] != 1 ||
        envelope['vault_id'] is! String) {
      throw const FormatException('不支持的资料库格式');
    }
  }

  dynamic _canonical(dynamic value) {
    if (value is Map) {
      final keys = value.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: _canonical(value[key])};
    }
    if (value is List) return value.map(_canonical).toList();
    return value;
  }

  String _envelopeAad(Json envelope) =>
      'xingji-envelope:1:${jsonEncode(_canonical({...envelope}..remove('proof')))}';
  Json _prove(Json envelope) => {
    ...envelope,
    'proof': _seal(Uint8List(0), _key!, _envelopeAad(envelope)),
  };
  void verifyEnvelope(Json envelope) {
    _validateEnvelope(envelope);
    if (envelope['vault_id'] != vaultId) {
      throw const FormatException('资料库密钥包身份不匹配');
    }
    _open(
      Map<String, dynamic>.from(envelope['proof'] as Map),
      _key!,
      _envelopeAad(envelope),
    );
  }

  void unlockTrusted(String id, Uint8List raw) {
    if (raw.length != 32) throw const FormatException('可信设备密钥无效');
    lock();
    vaultId = id;
    _key = sodium.secureCopy(raw);
  }

  T withKey<T>(T Function(Uint8List) action) => _key!.runUnlockedSync(action);

  Future<Json> changePassword(Json envelope, String password) async {
    if (password.length < 10) throw const FormatException('主密码至少需要 10 个字符');
    if (envelope['vault_id'] != vaultId) throw const FormatException('资料库不匹配');
    final kdf = _descriptor();
    final wrapper = await _derive(password, kdf);
    try {
      return _prove({
        ...envelope,
        'kdf': kdf,
        'password': _key!.runUnlockedSync(
          (raw) => _seal(raw, wrapper, 'xingji-key:1:$vaultId:password'),
        ),
      });
    } finally {
      wrapper.dispose();
    }
  }

  CipherRecord encrypt(Memo memo, {String? operationId}) {
    final packet = CipherRecord(
      vaultId: vaultId!,
      recordId: memo.id,
      operationId: operationId ?? uuid.v4(),
      nonce: '',
      payload: '',
      deleted: memo.deleted,
    );
    final plain = Uint8List.fromList(utf8.encode(jsonEncode(memo.toJson())));
    try {
      final sealed = _seal(plain, _key!, packet.aad);
      return CipherRecord.fromJson({...packet.toJson(), ...sealed});
    } finally {
      plain.fillRange(0, plain.length, 0);
    }
  }

  Memo decrypt(CipherRecord packet) {
    if (packet.vaultId != vaultId) throw const FormatException('密文不属于当前资料库');
    final raw = _open(packet.toJson(), _key!, packet.aad);
    try {
      final memo = Memo.fromJson(jsonDecode(utf8.decode(raw)) as Json);
      if (memo.id != packet.recordId || memo.deleted != packet.deleted) {
        throw const FormatException('记录身份认证失败');
      }
      if (memo.purged &&
          (!memo.deleted ||
              memo.title.isNotEmpty ||
              memo.body.isNotEmpty ||
              memo.tags.isNotEmpty ||
              memo.checklist.isNotEmpty ||
              memo.dueAt != null ||
              memo.snoozedUntil != null ||
              memo.completedAt != null ||
              memo.conflictOf != null ||
              memo.recurrence != 'none' ||
              memo.reminderOffsets.isNotEmpty)) {
        throw const FormatException('永久删除标记格式不正确');
      }
      return memo;
    } finally {
      raw.fillRange(0, raw.length, 0);
    }
  }

  SecureKey _imageKey(ImageAttachment image, String purpose) {
    final key = _key;
    if (key == null) throw const FormatException('请先解锁资料库');
    // The vault data key is already a uniformly random 256-bit master key.
    return sodium.crypto.kdfHkdfSha256.expand(
      masterKey: key,
      context: 'xingji-image:1:$purpose:$vaultId:${image.id}',
      outLen: 32,
    );
  }

  Uint8List _imageAad(ImageAttachment image, Object binding) => utf8.encode(
    jsonEncode([
      'xingji-image',
      1,
      vaultId,
      image.originId,
      image.id,
      ImageAttachment.mimeType,
      image.width,
      image.height,
      image.byteLength,
      image.chunkCount,
      binding,
    ]),
  );

  MemoImageLink linkImage(String memoId, ImageAttachment image) {
    image.validate();
    final key = _imageKey(image, 'link');
    try {
      return (
        memoId: memoId,
        image: image,
        tag: sodium.crypto.auth(message: _imageAad(image, memoId), key: key),
      );
    } finally {
      key.dispose();
    }
  }

  void verifyImageLink(MemoImageLink link) {
    link.image.validate();
    final key = _imageKey(link.image, 'link');
    try {
      if (link.tag.length != sodium.crypto.auth.bytes ||
          !sodium.crypto.auth.verify(
            tag: link.tag,
            message: _imageAad(link.image, link.memoId),
            key: key,
          )) {
        throw const FormatException('图片引用校验失败');
      }
    } finally {
      key.dispose();
    }
  }

  MemoImageLink relinkImage(MemoImageLink source, String memoId) {
    verifyImageLink(source);
    return linkImage(memoId, source.image);
  }

  List<ImageChunk> encryptImage(ImageAttachment image, Uint8List jpeg) {
    image.validate();
    if (jpeg.length != image.byteLength) throw const FormatException('图片长度不一致');
    final key = _imageKey(image, 'chunks');
    final aead = sodium.crypto.aeadXChaCha20Poly1305IETF;
    try {
      final chunks = <ImageChunk>[];
      for (var i = 0; i < image.chunkCount; i++) {
        final start = i * ImageAttachment.chunkBytes;
        final end = (start + ImageAttachment.chunkBytes).clamp(0, jpeg.length);
        final nonce = sodium.randombytes.buf(aead.nonceBytes);
        final ciphertext = aead.encrypt(
          message: Uint8List.sublistView(jpeg, start, end),
          additionalData: _imageAad(image, i),
          nonce: nonce,
          key: key,
        );
        chunks.add((nonce: nonce, ciphertext: ciphertext));
      }
      return chunks;
    } finally {
      key.dispose();
    }
  }

  Uint8List decryptImage(MemoImageLink link, List<ImageChunk> chunks) {
    verifyImageLink(link);
    final image = link.image;
    if (chunks.length != image.chunkCount) {
      throw const FormatException('图片分块不完整');
    }
    final key = _imageKey(image, 'chunks');
    final aead = sodium.crypto.aeadXChaCha20Poly1305IETF;
    final jpeg = Uint8List(image.byteLength);
    try {
      var offset = 0;
      for (var i = 0; i < chunks.length; i++) {
        final chunk = chunks[i];
        final length = (jpeg.length - offset).clamp(
          0,
          ImageAttachment.chunkBytes,
        );
        if (chunk.nonce.length != aead.nonceBytes ||
            chunk.ciphertext.length != length + aead.aBytes) {
          throw const FormatException('图片分块长度无效');
        }
        final plain = aead.decrypt(
          cipherText: chunk.ciphertext,
          additionalData: _imageAad(image, i),
          nonce: chunk.nonce,
          key: key,
        );
        jpeg.setAll(offset, plain);
        offset += plain.length;
        plain.fillRange(0, plain.length, 0);
      }
      return jpeg;
    } catch (_) {
      jpeg.fillRange(0, jpeg.length, 0);
      rethrow;
    } finally {
      key.dispose();
    }
  }

  Json encryptBackup(Json envelope, Json snapshot) {
    final raw = Uint8List.fromList(utf8.encode(jsonEncode(snapshot)));
    try {
      return {
        'kind': 'xingji-backup',
        'format': 1,
        'envelope': envelope,
        ..._seal(raw, _key!, 'xingji-backup:1:$vaultId'),
      };
    } finally {
      raw.fillRange(0, raw.length, 0);
    }
  }

  Json decryptBackup(Json backup) {
    if (backup['kind'] != 'xingji-backup' || backup['format'] != 1) {
      throw const FormatException('不是支持的星记备份文件');
    }
    final raw = _open(backup, _key!, 'xingji-backup:1:$vaultId');
    try {
      return jsonDecode(utf8.decode(raw)) as Json;
    } finally {
      raw.fillRange(0, raw.length, 0);
    }
  }

  void lock() {
    _key?.dispose();
    _key = null;
    vaultId = null;
  }
}
