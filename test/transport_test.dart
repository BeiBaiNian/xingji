import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:postgres/postgres.dart';
import 'package:xingji/core/models.dart';
import 'package:xingji/core/sync_engine.dart';
import 'package:xingji/core/vault_crypto.dart';

void main() {
  final enabled = Platform.environment['XINGJI_PG_TEST'] == '1';
  final ca = Platform.environment['XINGJI_TEST_CA'];
  test('TLS：信任测试 CA 后连接成功，错误主机名和未信任证书均拒绝', () async {
    ConnectionConfig config(String host, {String? certificate}) =>
        ConnectionConfig(
          host: host,
          port: 55473,
          database: 'postgres',
          username: 'test_device_a',
          caPath: certificate ?? '',
          tls: true,
        );
    final valid = await SyncEngine.open(config('localhost', certificate: ca));
    expect(
      (await valid.execute(
        'SELECT ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid()',
      )).first.first,
      true,
    );
    await valid.close();
    await expectLater(
      SyncEngine.open(config('127.0.0.1', certificate: ca)),
      throwsA(anything),
    );
    await expectLater(SyncEngine.open(config('localhost')), throwsA(anything));
  }, skip: !enabled || ca == null);

  test('事务游标：第二个写入等待第一个事务提交，不会漏读', () async {
    ConnectionConfig config() => const ConnectionConfig(
      host: '127.0.0.1',
      port: 55473,
      database: 'postgres',
      username: 'test_device_a',
      tls: false,
    );
    final crypto = await VaultCrypto.initialize();
    final created = await crypto.create('cursor-serialization-test');
    final c1 = await SyncEngine.open(config()),
        c2 = await SyncEngine.open(config());
    final vault = crypto.vaultId!, device = uuid.v4();
    Future<Result> write(Connection c, CipherRecord packet) => c.execute(
      Sql.named('SELECT xingji.api_put(@v::uuid,@d::uuid,0,@p::jsonb)'),
      parameters: {
        'v': vault,
        'd': device,
        'p': TypedValue(Type.jsonb, packet.toJson()),
      },
    );
    try {
      await c1.execute(
        Sql.named('SELECT xingji.api_bootstrap(@v::uuid,@e::jsonb,@d::uuid)'),
        parameters: {
          'v': vault,
          'e': TypedValue(Type.jsonb, created.envelope),
          'd': device,
        },
      );
      await c1.execute('BEGIN');
      final first =
          (await write(
                c1,
                crypto.encrypt(Memo(title: 'first cursor')),
              )).first.first
              as Map;
      var secondFinished = false;
      final secondFuture =
          write(c2, crypto.encrypt(Memo(title: 'second cursor'))).then((r) {
            secondFinished = true;
            return r;
          });
      await Future<void>.delayed(const Duration(milliseconds: 180));
      expect(secondFinished, false);
      await c1.execute('COMMIT');
      final second = (await secondFuture).first.first as Map;
      expect(first['cursor'], 1);
      expect(second['cursor'], 2);
      final changes =
          (await c1.execute(
                Sql.named('SELECT xingji.api_changes(@v::uuid,0)'),
                parameters: {'v': vault},
              )).first.first
              as List;
      expect(changes.map((c) => (c as Map)['cursor']), [1, 2]);
    } finally {
      await c1.close();
      await c2.close();
      crypto.lock();
    }
  }, skip: !enabled);
}
