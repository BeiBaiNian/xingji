// Explicit maintenance helper; never runs with the app or default test suite.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:postgres/postgres.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:xingji/core/models.dart';
import 'package:xingji/core/sync_engine.dart';
import 'package:xingji/platform/dpapi.dart';

void main() {
  test('读取已配置数据库的版本与升级权限，凭据不输出', () async {
    final profile = Platform.environment['XINGJI_INSPECT_PROFILE'];
    if (profile == null) throw StateError('必须显式指定 XINGJI_INSPECT_PROFILE');
    final databaseFile = File('$profile/vault.sqlite3');
    final closedProfile =
        Platform.environment['XINGJI_INSPECT_CLOSED_PROFILE'] == '1';
    if (closedProfile &&
        (File('${databaseFile.path}-wal').existsSync() ||
            File('${databaseFile.path}-journal').existsSync())) {
      throw StateError('资料库仍有事务日志；请正常退出星记后再核查');
    }
    // A closed WAL-mode database can otherwise need writable SHM sidecars
    // even for a read-only connection. Opt in only after normal app exit.
    final db = sqlite3.open(
      closedProfile
          ? databaseFile.absolute.uri
                .replace(queryParameters: {'immutable': '1'})
                .toString()
          : databaseFile.path,
      mode: OpenMode.readOnly,
      uri: closedProfile,
    );
    late ConnectionConfig config;
    try {
      final protected =
          db
                  .select("SELECT value FROM meta WHERE key='connection'")
                  .firstOrNull?['value']
              as String?;
      if (protected == null) throw StateError('此资料库没有保存数据库连接');
      final raw = Dpapi.unprotect(base64Decode(protected));
      try {
        config = ConnectionConfig.fromJson(
          jsonDecode(utf8.decode(raw)) as Json,
        );
      } finally {
        raw.fillRange(0, raw.length, 0);
      }
    } finally {
      db.close();
    }
    final connection = await SyncEngine.open(config);
    try {
      final result = (await connection.execute(
        '''SELECT current_database(),session_user,
        xingji.api_version(),(SELECT rolsuper FROM pg_roles WHERE rolname=session_user)
        OR (SELECT pg_has_role(session_user,nspowner,'MEMBER') FROM pg_namespace WHERE nspname='xingji')''',
      )).first;
      // Only connection identity and capabilities are printed, never passwords,
      // protected connection blobs, vault keys or memo payloads.
      stdout.writeln(
        jsonEncode({
          'host': config.host,
          'port': config.port,
          'database': result[0],
          'role': result[1],
          'version': result[2],
          'canUpgrade': result[3],
        }),
      );
      if (Platform.environment['XINGJI_APPLY_UPGRADE'] == '1') {
        if (result[3] != true) throw StateError('当前账号没有 schema 升级权限');
        final sql = await File('database/002_permanent_delete.sql')
            .readAsString();
        await connection.execute(sql, queryMode: QueryMode.simple);
        expect(
          (await connection.execute('SELECT xingji.api_version()')).first.first,
          2,
        );
        stdout.writeln(
          'Schema upgrade completed; no memo deletion was requested.',
        );
      }
    } finally {
      await connection.close();
    }
  });
}
