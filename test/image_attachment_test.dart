import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:sqlite3/sqlite3.dart';
import 'package:xingji/core/image_attachment.dart';
import 'package:xingji/core/local_store.dart';
import 'package:xingji/core/models.dart';
import 'package:xingji/core/vault_crypto.dart';
import 'package:xingji/platform/image_processing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late VaultCrypto crypto;
  late LocalStore store;
  late Memo memo;
  late CipherRecord packet;
  late Json envelope;
  const password = 'isolated-attachment-test';
  setUpAll(() async {
    crypto = await VaultCrypto.initialize();
    envelope = (await crypto.create(password)).envelope;
  });
  tearDownAll(() => crypto.lock());
  setUp(() {
    store = LocalStore(':memory:');
    memo = Memo(title: '图片测试');
    packet = crypto.encrypt(memo);
    store.saveLocal(packet);
  });
  tearDown(() => store.close());

  MemoImageLink add(Uint8List bytes) {
    final image = ImageAttachment(uuid.v4(), memo.id, 64, 32, bytes.length);
    final link = crypto.linkImage(memo.id, image);
    store.addImage(link, crypto.encryptImage(image, bytes), packet.operationId);
    return link;
  }

  test('分块认证拒绝篡改、乱序、截断、跨图替换及跨备忘录挪用', () {
    final bytes = Uint8List.fromList(
      List.generate(ImageAttachment.chunkBytes * 2 + 13, (i) => i % 251),
    );
    final link = add(bytes);
    final chunks = store.imageChunks(link.image);
    expect(chunks, hasLength(3));
    expect(chunks.map((c) => base64Encode(c.nonce)).toSet(), hasLength(3));
    expect(crypto.decryptImage(link, chunks), bytes);
    expect(
      chunks.first.ciphertext.take(32),
      isNot(orderedEquals(bytes.take(32))),
    );
    expect(
      () => crypto.decryptImage(link, [chunks[1], chunks[0], chunks[2]]),
      throwsA(anything),
    );
    expect(
      () => crypto.decryptImage(link, chunks.sublist(0, 2)),
      throwsFormatException,
    );
    final other = add(bytes);
    expect(() => crypto.decryptImage(other, chunks), throwsA(anything));
    expect(
      () => crypto.decryptImage((
        memoId: uuid.v4(),
        image: link.image,
        tag: link.tag,
      ), chunks),
      throwsFormatException,
    );
    chunks.last.ciphertext[0] ^= 1;
    expect(() => crypto.decryptImage(link, chunks), throwsA(anything));
  });

  test('旧资料库升级后保留正文，图片重启可读且不进入 outbox 与备份', () async {
    final temp = await Directory.systemTemp.createTemp('xingji-image-v2-');
    try {
      final path = '${temp.path}/vault.sqlite3';
      final v2 = sqlite3.open(path);
      v2.execute(
        'CREATE TABLE records (id TEXT PRIMARY KEY, packet TEXT NOT NULL, revision INTEGER NOT NULL, server_revision INTEGER NOT NULL DEFAULT 0)',
      );
      v2.execute('INSERT INTO records VALUES(?,?,1,1)', [
        memo.id,
        jsonEncode(packet.toJson()),
      ]);
      v2.execute('PRAGMA user_version=2');
      v2.close();
      final upgraded = LocalStore(path);
      final bytes = Uint8List.fromList(List.generate(1500, (i) => i % 127));
      final image = ImageAttachment(uuid.v4(), memo.id, 10, 15, bytes.length);
      try {
        expect(
          upgraded.db.select('PRAGMA user_version').single.values.single,
          3,
        );
        expect(crypto.decrypt(upgraded.get(memo.id)!.packet).title, memo.title);
        upgraded.addImage(
          crypto.linkImage(memo.id, image),
          crypto.encryptImage(image, bytes),
          packet.operationId,
        );
        expect(upgraded.pendingCount, 0);
        expect(upgraded.get(memo.id)!.packet.operationId, packet.operationId);
        final backup = crypto.decryptBackup(
          crypto.encryptBackup(envelope, upgraded.snapshot()),
        );
        expect(jsonEncode(backup), isNot(contains(image.id)));
        expect(
          backup.keys,
          unorderedEquals(['format', 'records', 'history', 'purges']),
        );
      } finally {
        upgraded.close();
      }
      final reopened = LocalStore(path);
      final second = await VaultCrypto.initialize();
      try {
        await second.unlock(envelope, password);
        final link = reopened.imageLinks(memo.id).single;
        expect(
          second.decryptImage(link, reopened.imageChunks(link.image)),
          bytes,
        );
        second.lock();
        expect(
          () => second.decryptImage(link, reopened.imageChunks(link.image)),
          throwsFormatException,
        );
      } finally {
        second.lock();
        reopened.close();
      }
    } finally {
      await temp.delete(recursive: true);
    }
  });

  test('添加失败整体回滚，数量、配额与并发修改在事务内校验', () {
    final bytes = Uint8List(20);
    store.db.execute(
      """CREATE TRIGGER fail_chunk BEFORE INSERT ON attachment_chunks
      BEGIN SELECT RAISE(ABORT, 'test'); END""",
    );
    expect(() => add(bytes), throwsA(isA<SqliteException>()));
    expect(store.db.select('SELECT id FROM attachments'), isEmpty);
    store.db.execute('DROP TRIGGER fail_chunk');
    final first = add(bytes);
    store.db.execute('UPDATE attachments SET byte_length=?', [
      ImageAttachment.maxVaultBytes,
    ]);
    expect(() => add(bytes), throwsFormatException);
    store.db.execute('UPDATE attachments SET byte_length=?', [bytes.length]);
    for (var i = 1; i < ImageAttachment.maxPerMemo; i++) {
      add(bytes);
    }
    expect(() => add(bytes), throwsFormatException);
    expect(store.imageLinks(memo.id), hasLength(9));
    expect(
      () => store.removeImage(memo.id, first.image.id, uuid.v4()),
      throwsFormatException,
    );
    store.removeImage(memo.id, first.image.id, packet.operationId);
    expect(store.imageChunks(first.image), isEmpty);
    add(bytes);
    expect(store.imageLinks(memo.id), hasLength(9));
  });

  test('远端改文、新服务器重建、冲突副本和永久删除正确维护本机引用', () {
    final bytes = Uint8List.fromList([4, 5, 6]);
    final link = add(bytes);
    store.prepareNewServer([packet]);
    store.acknowledge(packet, 1);
    final remote = crypto.encrypt(memo.edit({'body': '旧客户端的文字更新'}));
    store.applyPage([(packet: remote, revision: 2)], 1);
    expect(
      crypto.decryptImage(
        store.imageLinks(memo.id).single,
        store.imageChunks(link.image),
      ),
      bytes,
    );
    final copy = crypto.encrypt(
      memo.edit({'id': uuid.v4(), 'conflict_of': memo.id}),
    );
    store.resolveConflict(
      memo.id,
      copy,
      remote,
      2,
      relinkImage: crypto.relinkImage,
    );
    final marker = crypto.encrypt(Memo.purgeMarker(memo.id));
    store.applyPage(
      [(packet: marker, revision: 3)],
      2,
      purgedIds: {marker.operationId},
    );
    expect(store.imageLinks(memo.id), isEmpty);
    expect(
      crypto.decryptImage(
        store.imageLinks(copy.recordId).single,
        store.imageChunks(link.image),
      ),
      bytes,
    );
    store.purgeLocal(crypto.encrypt(Memo.purgeMarker(copy.recordId)));
    expect(store.db.select('SELECT * FROM attachments'), isEmpty);
    expect(store.db.select('SELECT * FROM attachment_chunks'), isEmpty);
  });

  test('EXIF 方向烘入像素，去除描述与 GPS，长边缩放，透明像素合成白色', () async {
    final source = img.Image(width: 64, height: 24);
    for (final pixel in source) {
      pixel.setRgb(pixel.x < 32 ? 255 : 0, 0, pixel.x < 32 ? 0 : 255);
    }
    source.exif.imageIfd.orientation = 6;
    source.exif.imageIfd.imageDescription = 'private-location-test';
    source.exif.gpsIfd.gpsLatitudeRef = 'N';
    final input = img.encodeJpg(source);
    expect(latin1.decode(input), contains('Exif'));
    final rotated = await processMemoImage(input);
    expect((rotated.width, rotated.height), (24, 64));
    final decoded = img.decodeJpg(rotated.jpeg)!;
    expect(decoded.getPixel(12, 8).r, greaterThan(220));
    expect(decoded.getPixel(12, 54).b, greaterThan(220));
    expect(latin1.decode(rotated.jpeg), isNot(contains('Exif')));
    expect(
      latin1.decode(rotated.jpeg),
      isNot(contains('private-location-test')),
    );
    final transparent = img.Image(width: 3072, height: 12, numChannels: 4);
    final small = await processMemoImage(img.encodePng(transparent));
    expect((small.width, small.height), (2048, 8));
    expect(img.decodeJpg(small.jpeg)!.getPixel(5, 2).r, greaterThan(245));
    await expectLater(
      processMemoImage(Uint8List.fromList([1, 2, 3])),
      throwsFormatException,
    );
  });

  test('WebP 可导入，GIF 只保留首帧', () async {
    final first = img.Image(width: 24, height: 16);
    img.fill(first, color: img.ColorRgb8(255, 0, 0));
    final webp = await processMemoImage(img.encodeWebP(first));
    expect((webp.width, webp.height), (24, 16));
    final second = img.Image(width: 24, height: 16);
    img.fill(second, color: img.ColorRgb8(0, 0, 255));
    first.addFrame(second);
    final gif = img.encodeGif(first);
    expect(img.decodeGif(gif)!.numFrames, 2);
    final saved = img.decodeJpg((await processMemoImage(gif)).jpeg)!;
    expect(saved.numFrames, 1);
    expect(saved.getPixel(10, 8).r, greaterThan(240));
    expect(saved.getPixel(10, 8).b, lessThan(15));
  });

  test('Windows DIB 剪贴板含调色板或位掩码时，正确计算像素偏移', () async {
    final dib = Uint8List(40 + 8 + 4);
    final header = ByteData.sublistView(dib);
    header.setUint32(0, 40, Endian.little);
    header.setInt32(4, 2, Endian.little);
    header.setInt32(8, 1, Endian.little);
    header.setUint16(12, 1, Endian.little);
    header.setUint16(14, 1, Endian.little);
    dib.setAll(44, [255, 255, 255, 0, 0x80]);
    final bmp = bmpFromClipboardDib(dib);
    expect(ByteData.sublistView(bmp).getUint32(10, Endian.little), 62);
    final image = img.decodeJpg((await processMemoImage(bmp)).jpeg)!;
    expect(image.getPixel(0, 0).r, greaterThan(240));
    expect(image.getPixel(1, 0).r, lessThan(15));
    final masked = Uint8List(40 + 12 + 4)..setAll(0, dib.sublist(0, 40));
    final info = ByteData.sublistView(masked);
    info.setUint16(14, 16, Endian.little);
    info.setUint32(16, 3, Endian.little);
    expect(
      ByteData.sublistView(bmpFromClipboardDib(masked))
          .getUint32(10, Endian.little),
      66,
    );
    expect(
      () => bmpFromClipboardDib(dib.sublist(0, 50)),
      throwsFormatException,
    );
  });
}
