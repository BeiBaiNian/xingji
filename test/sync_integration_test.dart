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
  test(
    '隔离 PostgreSQL：双设备同步、冲突、权限、幂等、游标和篡改保护',
    () async {
      final cryptoA = await VaultCrypto.initialize(),
          cryptoB = await VaultCrypto.initialize();
      final created = await cryptoA.create('integration-test-passphrase');
      await cryptoB.unlock(created.envelope, 'integration-test-passphrase');
      final a = LocalStore(':memory:'), b = LocalStore(':memory:');
      a.setMeta('envelope', jsonEncode(created.envelope));
      b.setMeta('envelope', jsonEncode(created.envelope));
      final engineA = SyncEngine(a, cryptoA, onChanged: () {}, onState: () {});
      final engineB = SyncEngine(b, cryptoB, onChanged: () {}, onState: () {});
      ConnectionConfig config(String user) => ConnectionConfig(
        host: '127.0.0.1',
        port: 55473,
        database: 'postgres',
        username: user,
        tls: false,
      );
      engineA.config = config('test_device_a');
      engineB.config = config('test_device_b');
      final admin = await SyncEngine.open(config('xingji_test_admin'));
      final vault = cryptoA.vaultId!;
      Future<Map> put(Connection c, String device, PendingOperation op) async =>
          (await c.execute(
                Sql.named(
                  'SELECT xingji.api_put(@v::uuid,@d::uuid,@b::bigint,@p::jsonb)',
                ),
                parameters: {
                  'v': vault,
                  'd': device,
                  'b': op.baseRevision,
                  'p': TypedValue(Type.jsonb, op.packet.toJson()),
                },
              )).first.first
              as Map;
      try {
        final original = Memo(
          title: 'PG_SECRET_TITLE_971',
          body: 'PG_SECRET_BODY_971',
          tags: ['PG_SECRET_TAG_971'],
          dueAt: DateTime.utc(2030, 7, 20, 6),
        );
        a.saveLocal(cryptoA.encrypt(original));
        await engineA.sync();
        expect(engineA.hasError, false, reason: engineA.status);
        expect(a.pendingCount, 0);
        await admin.execute(
          Sql.named(
            'INSERT INTO xingji.vault_access(vault_id,db_role) VALUES(@v::uuid,\'test_device_b\')',
          ),
          parameters: {'v': vault},
        );
        await engineB.sync();
        expect(engineB.hasError, false, reason: engineB.status);
        expect(
          cryptoB.decrypt(b.get(original.id)!.packet).title,
          original.title,
        );
        b.saveLocal(
          cryptoB.encrypt(
            cryptoB.decrypt(b.get(original.id)!.packet).complete(),
          ),
        );
        await engineB.sync();
        await engineA.sync();
        expect(cryptoA.decrypt(a.get(original.id)!.packet).done, true);

        // Both clients edit while disconnected, starting from the same base revision.
        a.saveLocal(
          cryptoA.encrypt(
            cryptoA.decrypt(a.get(original.id)!.packet).edit({
              'title': '设备A的修改',
              'status': 'open',
            }),
          ),
        );
        b.saveLocal(
          cryptoB.encrypt(
            cryptoB.decrypt(b.get(original.id)!.packet).edit({
              'title': '设备B的修改',
              'status': 'open',
            }),
          ),
        );
        await engineA.sync();
        await engineB.sync();
        await engineA.sync();
        expect(engineB.hasError, false, reason: engineB.status);
        expect(cryptoB.decrypt(b.get(original.id)!.packet).title, '设备A的修改');
        final copies = b
            .all()
            .map((r) => cryptoB.decrypt(r.packet))
            .where((m) => m.conflictOf == original.id)
            .toList();
        expect(copies.length, 1);
        expect(copies.single.title, contains('设备B的修改'));
        expect(a.all().length, 2);

        // Simulate server commit followed by a lost response, then retry the outbox.
        final retryMemo = cryptoA.decrypt(a.get(original.id)!.packet).edit({
          'body': 'retry-final',
        });
        a.saveLocal(cryptoA.encrypt(retryMemo));
        final op = a.pending().first;
        final direct = await SyncEngine.open(config('test_device_a'));
        final first = await put(direct, a.deviceId, op),
            second = await put(direct, a.deviceId, op);
        expect(first['revision'], second['revision']);
        expect(first['cursor'], second['cursor']);
        await direct.close();
        await engineA.sync();
        expect(a.pendingCount, 0);
        expect(engineA.hasError, false, reason: engineA.status);

        // Role authorization is independent from the supplied device_id.
        final stranger = await SyncEngine.open(config('test_stranger'));
        await expectLater(
          stranger.execute(
            Sql.named('SELECT xingji.api_changes(@v::uuid,0)'),
            parameters: {'v': vault},
          ),
          throwsA(isA<ServerException>()),
        );
        await expectLater(
          stranger.execute('SELECT * FROM xingji.records'),
          throwsA(isA<ServerException>()),
        );
        await stranger.close();
        final deviceB = await SyncEngine.open(config('test_device_b'));
        a.saveLocal(cryptoA.encrypt(retryMemo.edit({'body': 'role-check'})));
        await expectLater(
          put(deviceB, a.deviceId, a.pending().first),
          throwsA(isA<ServerException>()),
        );
        await deviceB.close();
        await engineA.sync();
        await engineB.sync();

        // A deleted task becomes an authenticated tombstone on the other client.
        a.saveLocal(
          cryptoA.encrypt(
            cryptoA.decrypt(a.get(original.id)!.packet).edit({
              'deleted_at': DateTime.now().toUtc().toIso8601String(),
            }),
          ),
        );
        await engineA.sync();
        await engineB.sync();
        expect(cryptoB.decrypt(b.get(original.id)!.packet).deleted, true);

        // Offline concurrent password changes need an explicit resolution.
        Future<void> changeEnvelope(
          LocalStore store,
          VaultCrypto crypto,
          String password,
        ) async {
          store.setMeta(
            'envelope',
            jsonEncode(await crypto.changePassword(store.envelope!, password)),
          );
          store.setMeta('envelope_dirty', 'true');
        }

        await changeEnvelope(a, cryptoA, 'new-password-on-device-A');
        await changeEnvelope(b, cryptoB, 'new-password-on-device-B');
        await engineA.sync();
        await engineB.sync();
        expect(engineB.envelopeConflict, true);
        expect(engineB.hasError, true);
        await engineB.resolveEnvelopeConflict(keepLocal: true);
        expect(engineB.hasError, false, reason: engineB.status);
        await engineA.sync();
        final passwordCheck = await VaultCrypto.initialize();
        await passwordCheck.unlock(a.envelope!, 'new-password-on-device-B');
        expect(passwordCheck.decrypt(a.get(original.id)!.packet).deleted, true);
        passwordCheck.lock();
        await changeEnvelope(a, cryptoA, 'second-password-on-device-A');
        await changeEnvelope(b, cryptoB, 'second-password-on-device-B');
        await engineA.sync();
        await engineB.sync();
        expect(engineB.envelopeConflict, true);
        await engineB.resolveEnvelopeConflict(keepLocal: false);
        expect(engineB.hasError, false, reason: engineB.status);
        await passwordCheck.unlock(b.envelope!, 'second-password-on-device-A');
        passwordCheck.lock();

        final dump = (await admin.execute(
          Sql.named(
            'SELECT packet::text FROM xingji.changes WHERE vault_id=@v::uuid',
          ),
          parameters: {'v': vault},
        )).map((r) => r.first).join();
        for (final sentinel in [
          'PG_SECRET_TITLE_971',
          'PG_SECRET_BODY_971',
          'PG_SECRET_TAG_971',
          '2030-07-20',
          '设备A的修改',
          '设备B的修改',
        ]) {
          expect(dump, isNot(contains(sentinel)));
        }

        // Corrupt a not-yet-pulled change. The receiver must retain its valid record and cursor.
        final beforeCursor = b.cursor;
        final beforePacket = b.get(original.id)!.packet.payload;
        a.saveLocal(
          cryptoA.encrypt(
            cryptoA.decrypt(a.get(original.id)!.packet).edit({
              'body': 'tamper-target',
            }),
          ),
        );
        await engineA.sync();
        await admin.execute(
          Sql.named(
            'UPDATE xingji.changes SET packet=jsonb_set(packet,\'{payload}\',to_jsonb(\'AAAAAAAAAAAAAAAAAAAAAA==\'::text)) WHERE vault_id=@v::uuid AND cursor=(SELECT max(cursor) FROM xingji.changes WHERE vault_id=@v::uuid)',
          ),
          parameters: {'v': vault},
        );
        await engineB.sync();
        expect(engineB.hasError, true);
        expect(b.cursor, beforeCursor);
        expect(b.get(original.id)!.packet.payload, beforePacket);
      } finally {
        await engineA.disconnect();
        await engineB.disconnect();
        await admin.close();
        a.close();
        b.close();
        cryptoA.lock();
        cryptoB.lock();
      }
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
