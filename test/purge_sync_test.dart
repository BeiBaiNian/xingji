import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:postgres/postgres.dart';
import 'package:xingji/core/local_store.dart';
import 'package:xingji/core/models.dart';
import 'package:xingji/core/sync_engine.dart';
import 'package:xingji/core/vault_crypto.dart';

void main() {
  final enabled = Platform.environment['XINGJI_PG_TEST'] == '1';
  ConnectionConfig config(String user) => ConnectionConfig(
    host: '127.0.0.1',
    port: 55473,
    database: 'postgres',
    username: user,
    tls: false,
  );

  test(
    'PG 永久删除：清理历史、丢包重试、离线旧修改/旧备份不复活、权限隔离',
    () async {
      final a = LocalStore(':memory:'),
          b = LocalStore(':memory:'),
          c = LocalStore(':memory:');
      final ca = await VaultCrypto.initialize(),
          cb = await VaultCrypto.initialize(),
          cc = await VaultCrypto.initialize();
      final created = await ca.create('purge-pg-isolated-passphrase');
      await cb.unlock(created.envelope, 'purge-pg-isolated-passphrase');
      await cc.unlock(created.envelope, 'purge-pg-isolated-passphrase');
      for (final store in [a, b, c]) {
        store.setMeta('envelope', jsonEncode(created.envelope));
      }
      final ea = SyncEngine(a, ca, onChanged: () {}, onState: () {})
        ..config = config('test_device_a');
      final eb = SyncEngine(b, cb, onChanged: () {}, onState: () {})
        ..config = config('test_device_b');
      final ec = SyncEngine(c, cc, onChanged: () {}, onState: () {})
        ..config = config('test_device_b');
      final admin = await SyncEngine.open(config('xingji_test_admin'));
      final direct = await SyncEngine.open(config('test_device_a'));
      final vault = ca.vaultId!;
      final original = Memo(title: '隔离测试永久清理', body: '不能回来的旧内容');
      final oldPacket = ca.encrypt(original);
      try {
        a.saveLocal(oldPacket);
        await ea.sync();
        expect(ea.hasError, false, reason: ea.status);
        a.saveLocal(ca.encrypt(original.edit({'body': '第二版旧内容'})));
        await ea.sync();
        await admin.execute(
          Sql.named(
            "INSERT INTO xingji.vault_access VALUES(@v::uuid,'test_device_b')",
          ),
          parameters: {'v': vault},
        );
        await eb.sync();
        b.saveLocal(
          cb.encrypt(
            cb.decrypt(b.get(original.id)!.packet).edit({'body': '离线编辑'}),
          ),
        );
        final keep = Memo(title: '其他正常事项');
        b.saveLocal(cb.encrypt(keep));
        final marker = ca.encrypt(Memo.purgeMarker(original.id));
        a.purgeLocal(marker);
        Future<Map> purge(Connection connection, String device) async =>
            (await connection.execute(
                  Sql.named(
                    'SELECT xingji.api_purge(@v::uuid,@d::uuid,@p::jsonb)',
                  ),
                  parameters: {
                    'v': vault,
                    'd': device,
                    'p': TypedValue(Type.jsonb, marker.toJson()),
                  },
                )).first.first
                as Map;
        final first = await purge(direct, a.deviceId),
            retry = await purge(direct, a.deviceId);
        expect(first['cursor'], retry['cursor']);
        expect(first['revision'], retry['revision']);
        expect(a.pendingPurgeCount, 1);
        await ea.sync();
        expect(ea.hasError, false, reason: ea.status);
        expect(a.pendingCount, 0);
        await eb.sync();
        expect(eb.hasError, false, reason: eb.status);
        expect(b.get(original.id), isNull);
        expect(b.history(original.id), isEmpty);
        expect(b.pendingCount, 0);
        expect(cb.decrypt(b.all().single.packet).id, keep.id);
        final history = (await admin.execute(
          Sql.named(
            'SELECT packet FROM xingji.changes WHERE vault_id=@v::uuid AND record_id=@r::uuid ORDER BY cursor',
          ),
          parameters: {'v': vault, 'r': original.id},
        )).map((r) => Map<String, dynamic>.from(r.first as Map)).toList();
        expect(history.length, greaterThan(1));
        expect(history.every((p) => p.isEmpty), true);
        expect(jsonEncode(history), isNot(contains(oldPacket.payload)));
        expect(
          (await admin.execute(
            Sql.named(
              'SELECT count(*) FROM xingji.records WHERE vault_id=@v::uuid AND record_id=@r::uuid',
            ),
            parameters: {'v': vault, 'r': original.id},
          )).first.first,
          0,
        );
        // Fresh device restores a pre-deletion backup, then replays all cursors.
        c.saveLocal(oldPacket);
        await ec.sync();
        expect(ec.hasError, false, reason: ec.status);
        expect(c.get(original.id), isNull);
        expect(c.isPurged(original.id), true);
        expect(c.pendingCount, 0);
        expect(cc.decrypt(c.all().single.packet).id, keep.id);
        final stranger = await SyncEngine.open(config('test_stranger'));
        try {
          await expectLater(
            purge(stranger, a.deviceId),
            throwsA(isA<ServerException>()),
          );
        } finally {
          await stranger.close();
        }
        final other = await SyncEngine.open(config('test_device_b'));
        try {
          await expectLater(
            purge(other, a.deviceId),
            throwsA(isA<ServerException>()),
          );
          await expectLater(
            other.execute(
              Sql.named(
                'SELECT xingji.api_put_v1(@v::uuid,@d::uuid,0,@p::jsonb)',
              ),
              parameters: {
                'v': vault,
                'd': b.deviceId,
                'p': TypedValue(Type.jsonb, oldPacket.toJson()),
              },
            ),
            throwsA(isA<ServerException>()),
          );
        } finally {
          await other.close();
        }
        // A forged purge must not erase the receiver's record or advance its
        // cursor. Only the authenticated content-free marker can do that.
        final victim = Memo(title: '删除认证保护');
        a.saveLocal(ca.encrypt(victim));
        await ea.sync();
        await eb.sync();
        final before = b.get(victim.id)!.packet.payload;
        final beforeCursor = b.cursor;
        await eb.disconnect();
        final validMarker = ca.encrypt(Memo.purgeMarker(victim.id));
        a.purgeLocal(validMarker);
        await ea.sync();
        await admin.execute(
          Sql.named(
            "UPDATE xingji.purges SET packet=jsonb_set(packet,'{payload}',to_jsonb('AAAAAAAAAAAAAAAAAAAAAA=='::text)) WHERE vault_id=@v::uuid AND record_id=@r::uuid",
          ),
          parameters: {'v': vault, 'r': victim.id},
        );
        await eb.sync();
        expect(eb.hasError, true);
        expect(b.cursor, beforeCursor);
        expect(b.get(victim.id)!.packet.payload, before);
        await admin.execute(
          Sql.named(
            'UPDATE xingji.purges SET packet=@p::jsonb WHERE vault_id=@v::uuid AND record_id=@r::uuid',
          ),
          parameters: {
            'v': vault,
            'r': victim.id,
            'p': TypedValue(Type.jsonb, validMarker.toJson()),
          },
        );
        await eb.sync();
        expect(eb.hasError, false, reason: eb.status);
        expect(b.get(victim.id), isNull);
      } finally {
        await ea.disconnect();
        await eb.disconnect();
        await ec.disconnect();
        await admin.close();
        await direct.close();
        a.close();
        b.close();
        c.close();
        ca.lock();
        cb.lock();
        cc.lock();
      }
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'PG v1 保留待删除队列且不误报成功，在线升级后同一连接继续清理',
    () async {
      final store = LocalStore(':memory:');
      final crypto = await VaultCrypto.initialize();
      final created = await crypto.create('purge-upgrade-test-passphrase');
      store.setMeta('envelope', jsonEncode(created.envelope));
      final engine = SyncEngine(store, crypto, onChanged: () {}, onState: () {})
        ..config = config('test_device_a');
      final admin = await SyncEngine.open(config('xingji_test_admin'));
      Future<void> version(int v) => admin
          .execute(
            'CREATE OR REPLACE FUNCTION xingji.api_version() RETURNS integer LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,xingji AS \$\$ SELECT $v \$\$',
          )
          .then((_) {});
      try {
        final memo = Memo(title: '待升级再删除');
        store.saveLocal(crypto.encrypt(memo));
        await engine.sync();
        expect(engine.hasError, false, reason: engine.status);
        await version(1);
        store.purgeLocal(crypto.encrypt(Memo.purgeMarker(memo.id)));
        store.saveLocal(crypto.encrypt(Memo(title: '普通同步继续')));
        await engine.sync();
        expect(engine.hasError, true);
        expect(engine.status, contains('002_permanent_delete.sql'));
        expect(store.pendingPurgeCount, 1);
        expect(store.pending(), isEmpty);
        await version(2);
        await engine.sync();
        expect(engine.hasError, false, reason: engine.status);
        expect(store.pendingCount, 0);
        expect(store.get(memo.id), isNull);
      } finally {
        await version(2);
        await engine.disconnect();
        await admin.close();
        store.close();
        crypto.lock();
      }
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
