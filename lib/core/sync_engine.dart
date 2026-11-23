import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart';

import '../platform/device_services.dart';

import 'local_store.dart';
import 'models.dart';
import 'vault_crypto.dart';

String safeError(Object error) {
  if (error is HandshakeException || error is TlsException) {
    return 'TLS 证书验证失败，请检查主机名和 CA 证书';
  }
  if (error is SocketException || error is TimeoutException) {
    return '暂时无法连接数据库，修改已保存在本机，将自动重试';
  }
  if (error is ServerException) {
    return switch (error.code) {
      '28P01' || '28000' => '数据库账号或密码不正确',
      '42501' => '当前数据库账号没有此资料库或设备的访问权限',
      '42883' || '42P01' || '3F000' => '数据库结构未就绪，请先执行初始化脚本',
      '3D000' => '数据库不存在，请检查数据库名称',
      '40001' => '另一设备已更改主密码，请先同步最新密钥包后重试',
      _ => '数据库操作未完成（${error.code ?? "未知代码"}），本地数据已保留',
    };
  }
  if (error is FormatException) return error.message;
  return '操作未完成，数据已保留。请检查连接或重新解锁后重试';
}

class SyncEngine {
  SyncEngine(
    this.store,
    this.crypto, {
    required this.onChanged,
    required this.onState,
  });
  final LocalStore store;
  final VaultCrypto crypto;
  final void Function() onChanged, onState;
  ConnectionConfig? config;
  Connection? _connection;
  StreamSubscription<Notification>? _subscription;
  Timer? _timer, _debounce;
  bool running = false;
  int serverVersion = 1;
  String status = '离线模式 · 数据保存在本机';
  DateTime? lastSuccess;
  List<Json> devices = [];
  bool hasError = false;
  Json? _conflictingEnvelope;
  int? _conflictingEnvelopeRevision;
  bool get envelopeConflict => _conflictingEnvelope != null;
  int _generation = 0;

  Future<void> resolveEnvelopeConflict({required bool keepLocal}) async {
    if (running) throw const FormatException('正在同步，请稍后重试');
    final remote = _conflictingEnvelope;
    final revision = _conflictingEnvelopeRevision;
    if (remote == null || revision == null || !crypto.unlocked) return;
    crypto.verifyEnvelope(remote);
    store.transaction(() {
      if (!keepLocal) {
        store.setMeta('envelope', jsonEncode(remote));
        store.removeMeta('envelope_dirty');
      }
      store.setMeta('envelope_revision', revision.toString());
    });
    _conflictingEnvelope = null;
    _conflictingEnvelopeRevision = null;
    await sync();
  }

  static Future<Connection> open(ConnectionConfig config) async {
    if (config.host.trim().isEmpty ||
        config.username.trim().isEmpty ||
        config.database.trim().isEmpty ||
        config.port < 1 ||
        config.port > 65535) {
      throw const FormatException('请填写主机、数据库、用户名和有效端口');
    }
    SecurityContext? context;
    if (config.tls && config.caPath.isNotEmpty) {
      context = SecurityContext(withTrustedRoots: true)
        ..setTrustedCertificates(config.caPath);
    }
    return Connection.open(
      Endpoint(
        host: config.host.trim(),
        port: config.port,
        database: config.database.trim(),
        username: config.username.trim(),
        password: config.password,
      ),
      settings: ConnectionSettings(
        sslMode: config.tls ? SslMode.verifyFull : SslMode.disable,
        securityContext: context,
        applicationName: 'XingJi',
        connectTimeout: const Duration(seconds: 8),
        queryTimeout: const Duration(seconds: 12),
      ),
    );
  }

  static Future<String> test(ConnectionConfig config) async {
    final connection = await open(config);
    try {
      final result = await connection.execute(
        'SELECT current_setting(\'server_version\'),xingji.api_version()',
      );
      if (![1, 2].contains(result.first[1])) {
        throw const FormatException('数据库结构版本不兼容');
      }
      return '连接成功 · PostgreSQL ${result.first[0]} · 结构 v${result.first[1]}';
    } finally {
      await connection.close();
    }
  }

  static Future<List<Json>> remoteVaults(ConnectionConfig config) async {
    final connection = await open(config);
    try {
      final result = await connection.execute(
        'SELECT xingji.api_list_vaults()',
      );
      return (result.first.first as List)
          .map((j) => Map<String, dynamic>.from(j as Map))
          .toList();
    } finally {
      await connection.close();
    }
  }

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(
      const Duration(minutes: 2),
      (_) => unawaited(sync()),
    );
    unawaited(sync());
  }

  Future<void> configure(
    ConnectionConfig? value, {
    bool autoStart = true,
  }) async {
    await disconnect();
    config = value;
    status = value == null ? '离线模式 · 数据保存在本机' : '等待同步';
    hasError = false;
    onState();
    if (value != null && autoStart) start();
  }

  Future<void> _dropConnection() async {
    await _subscription?.cancel();
    _subscription = null;
    final old = _connection;
    _connection = null;
    try {
      await old?.close();
    } catch (_) {
      /* Reconnect on the next cycle. */
    }
  }

  Future<void> disconnect() async {
    _generation++;
    _timer?.cancel();
    _debounce?.cancel();
    await _dropConnection();
  }

  Future<void> sync() async {
    if (running ||
        config == null ||
        !crypto.unlocked ||
        store.envelope == null) {
      return;
    }
    // Foreground and the Android background engine share one native gate.
    // Never run two sync loops against the same phone's outbox concurrently.
    running = true;
    final generation = _generation;
    final vault = crypto.vaultId!;
    var acquired = false;
    try {
      acquired = await DeviceServices.acquireSync();
      if (!acquired || generation != _generation || !crypto.unlocked) return;
      status = '正在同步…';
      onState();
      if (_connection == null || !_connection!.isOpen) {
        final connection = await open(config!);
        if (generation != _generation) {
          await connection.close();
          return;
        }
        _connection = connection;
        // Subscribe before pulling durable changes; NOTIFY carries no task fields.
        _subscription = connection.channels.all.listen((event) {
          if (event.channel == 'xingji_changes' && event.payload == vault) {
            _debounce?.cancel();
            _debounce = Timer(
              const Duration(milliseconds: 500),
              () => unawaited(sync()),
            );
          }
        }, onError: (_) {});
        await connection.execute('LISTEN xingji_changes');
      }
      final c = _connection!;
      serverVersion =
          (await c.execute('SELECT xingji.api_version()')).first.first as int;
      if (![1, 2].contains(serverVersion)) {
        throw const FormatException('数据库结构版本不兼容');
      }
      final bootstrap =
          (await c.execute(
                Sql.named(
                  'SELECT xingji.api_bootstrap(@v::uuid,@e::jsonb,@d::uuid)',
                ),
                parameters: {
                  'v': vault,
                  'e': TypedValue(Type.jsonb, store.envelope),
                  'd': store.deviceId,
                },
              )).first.first
              as Map;
      if (generation != _generation) return;
      final serverEnvelopeRevision = bootstrap['envelope_revision'] as int;
      if (bootstrap['created'] == true) {
        store.prepareNewServer(
          store
              .all()
              .map((r) => crypto.encrypt(crypto.decrypt(r.packet)))
              .toList(),
        );
      }
      if (store.envelopeDirty) {
        if (bootstrap['created'] == true) {
          store.setMeta('envelope_revision', serverEnvelopeRevision.toString());
        } else if (serverEnvelopeRevision != store.envelopeRevision) {
          final remote = Map<String, dynamic>.from(
            bootstrap['envelope'] as Map,
          );
          crypto.verifyEnvelope(remote);
          _conflictingEnvelope = remote;
          _conflictingEnvelopeRevision = serverEnvelopeRevision;
          throw const FormatException('两台设备都更改了主密码，请在“安全与备份”中选择保留哪一份');
        }
        final result = await c.execute(
          Sql.named(
            'SELECT xingji.api_update_envelope(@v::uuid,@b::bigint,@e::jsonb)',
          ),
          parameters: {
            'v': vault,
            'b': store.envelopeRevision,
            'e': TypedValue(Type.jsonb, store.envelope),
          },
        );
        if (generation != _generation) return;
        store.transaction(() {
          store.setMeta('envelope_revision', result.first.first.toString());
          store.removeMeta('envelope_dirty');
        });
        _conflictingEnvelope = null;
        _conflictingEnvelopeRevision = null;
      } else if (serverEnvelopeRevision > store.envelopeRevision ||
          bootstrap['created'] == false) {
        final envelope = Map<String, dynamic>.from(
          bootstrap['envelope'] as Map,
        );
        if (envelope['vault_id'] != vault || envelope['format'] != 1) {
          throw const FormatException('服务器密钥包不匹配');
        }
        crypto.verifyEnvelope(envelope);
        store.transaction(() {
          store.setMeta('envelope', jsonEncode(envelope));
          store.setMeta('envelope_revision', serverEnvelopeRevision.toString());
        });
      }
      // Permanent deletion is an authenticated, content-free operation. Send
      // it before ordinary edits so stale content never wins on this device.
      if (serverVersion >= 2) {
        for (final marker in store.purgeMarkers(pendingOnly: true).take(100)) {
          if (generation != _generation || !crypto.unlocked) return;
          if (!crypto.decrypt(marker).purged) {
            throw const FormatException('无效删除标记');
          }
          final response =
              (await c.execute(
                    Sql.named(
                      'SELECT xingji.api_purge(@v::uuid,@d::uuid,@p::jsonb)',
                    ),
                    parameters: {
                      'v': vault,
                      'd': store.deviceId,
                      'p': TypedValue(Type.jsonb, marker.toJson()),
                    },
                  )).first.first
                  as Map;
          if (generation != _generation || !crypto.unlocked) return;
          _acceptPurge(response, marker.recordId);
        }
      }
      // Bounded rounds keep a large outbox from monopolizing the UI indefinitely.
      for (var round = 0; round < 10; round++) {
        final pending = store.pending();
        if (pending.isEmpty) break;
        for (final operation in pending) {
          if (generation != _generation || !crypto.unlocked) return;
          if (!store.containsOperation(operation.packet.operationId)) continue;
          final response =
              (await c.execute(
                    Sql.named(
                      'SELECT xingji.api_put(@v::uuid,@d::uuid,@b::bigint,@p::jsonb)',
                    ),
                    parameters: {
                      'v': vault,
                      'd': store.deviceId,
                      'b': operation.baseRevision,
                      'p': TypedValue(Type.jsonb, operation.packet.toJson()),
                    },
                  )).first.first
                  as Map;
          if (generation != _generation || !crypto.unlocked) return;
          if (store.isPurged(operation.packet.recordId)) continue;
          if (response['status'] == 'ok') {
            store.acknowledge(operation.packet, response['revision'] as int);
          } else if (response['status'] == 'purged') {
            _acceptPurge(response, operation.packet.recordId);
          } else if (response['status'] == 'conflict') {
            final latest = store.get(operation.packet.recordId);
            if (latest == null) throw const FormatException('冲突记录缺失');
            final local = crypto.decrypt(latest.packet);
            final remote = response['packet'] == null
                ? null
                : CipherRecord.fromJson(
                    Map<String, dynamic>.from(response['packet'] as Map),
                  );
            if (remote != null) crypto.decrypt(remote);
            // Keep the latest local edit including any edits queued during the request.
            final copy = local.edit({
              'id': uuid.v4(),
              'title': '${local.title}（冲突副本）',
              'conflict_of': local.id,
              'deleted_at': null,
              'status': 'open',
            });
            store.resolveConflict(
              local.id,
              crypto.encrypt(copy),
              remote,
              response['revision'] as int,
              relinkImage: crypto.relinkImage,
            );
          } else {
            throw const FormatException('服务器返回了未知同步状态');
          }
        }
      }
      while (true) {
        final result = await c.execute(
          Sql.named('SELECT xingji.api_changes(@v::uuid,@c::bigint)'),
          parameters: {'v': vault, 'c': store.cursor},
        );
        if (generation != _generation || !crypto.unlocked) return;
        final rows = result.first.first as List;
        if (rows.isEmpty) break;
        var newCursor = store.cursor;
        final page = <({CipherRecord packet, int revision})>[];
        final purgedIds = <String>{};
        for (final row in rows) {
          final change = Map<String, dynamic>.from(row as Map);
          final packet = CipherRecord.fromJson(
            Map<String, dynamic>.from(change['packet'] as Map),
          );
          // Authentication is complete before any record or the cursor is changed.
          if (crypto.decrypt(packet).purged) purgedIds.add(packet.operationId);
          final cursor = change['cursor'] as int;
          if (cursor != newCursor + 1) {
            throw const FormatException('服务器变更游标不连续，已停止同步以保护数据');
          }
          newCursor = cursor;
          page.add((packet: packet, revision: change['revision'] as int));
        }
        store.applyPage(page, newCursor, purgedIds: purgedIds);
        if (rows.length < 200) break;
      }
      await c.execute(
        Sql.named('SELECT xingji.api_ack(@v::uuid,@d::uuid,@c::bigint)'),
        parameters: {'v': vault, 'd': store.deviceId, 'c': store.cursor},
      );
      final deviceResult = await c.execute(
        Sql.named('SELECT xingji.api_devices(@v::uuid)'),
        parameters: {'v': vault},
      );
      if (generation != _generation) return;
      devices = (deviceResult.first.first as List)
          .map((j) => Map<String, dynamic>.from(j as Map))
          .toList();
      lastSuccess = DateTime.now();
      final needsUpgrade = serverVersion < 2 && store.pendingPurgeCount > 0;
      status = needsUpgrade
          ? '${store.pendingPurgeCount} 项永久删除待同步，请执行数据库升级脚本 002_permanent_delete.sql'
          : store.pendingCount == 0
          ? '本机已同步'
          : '${store.pendingCount} 项等待同步';
      hasError = needsUpgrade;
      onChanged();
    } catch (error) {
      if (generation == _generation) {
        status = safeError(error);
        hasError = true;
        await _dropConnection();
        onChanged();
      }
    } finally {
      if (acquired) await DeviceServices.releaseSync();
      running = false;
      onState();
      if (generation == _generation &&
          !hasError &&
          (store.pendingCount > 0 || !acquired && _timer != null) &&
          crypto.unlocked) {
        _debounce?.cancel();
        _debounce = Timer(
          const Duration(milliseconds: 500),
          () => unawaited(sync()),
        );
      }
    }
  }

  void _acceptPurge(Map response, String recordId) {
    if (response['status'] != 'purged') {
      throw const FormatException('永久删除未获服务器确认');
    }
    final marker = CipherRecord.fromJson(
      Map<String, dynamic>.from(response['packet'] as Map),
    );
    if (marker.recordId != recordId || !crypto.decrypt(marker).purged) {
      throw const FormatException('永久删除凭据认证失败');
    }
    store.acceptPurge(marker, response['revision'] as int);
  }
}
