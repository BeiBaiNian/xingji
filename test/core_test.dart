import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:xingji/core/local_store.dart';
import 'package:xingji/core/models.dart';
import 'package:xingji/core/vault_crypto.dart';
import 'package:xingji/platform/dpapi.dart';

void main() {
  late VaultCrypto crypto;
  late Json envelope;
  late String recovery;
  const password = 'test-only-long-password-2026';
  setUpAll(() async {
    tzdata.initializeTimeZones();
    crypto = await VaultCrypto.initialize();
    final created = await crypto.create(password);
    envelope = created.envelope;
    recovery = created.recoveryCode;
  });
  tearDownAll(() => crypto.lock());

  test('独立实例可用主密码和恢复码解开同一密文', () async {
    final memo = Memo(
      title: '私密标题_测试',
      body: '正文_测试',
      tags: ['不可见标签'],
      dueAt: DateTime.utc(2030, 7, 20, 6),
    );
    final packet = crypto.encrypt(memo);
    final other = await VaultCrypto.initialize();
    await other.unlock(envelope, password);
    expect(other.decrypt(packet).toJson(), memo.toJson());
    other.lock();
    await other.unlock(envelope, recovery, recovery: true);
    expect(other.decrypt(packet).title, memo.title);
    other.lock();
    expect(jsonEncode(packet.toJson()), isNot(contains(memo.title)));
    expect(jsonEncode(packet.toJson()), isNot(contains('2030-07-20')));
  });
  test('同一任务每次写入使用新的 nonce 和 operation_id', () {
    final memo = Memo(title: 'nonce test');
    final a = crypto.encrypt(memo);
    final b = crypto.encrypt(memo);
    expect(a.nonce, isNot(b.nonce));
    expect(a.operationId, isNot(b.operationId));
    expect(a.payload, isNot(b.payload));
  });
  test('修改密文字节、记录 ID、删除标志均被认证拒绝', () {
    final packet = crypto.encrypt(Memo(title: 'integrity'));
    final bytes = base64Decode(packet.payload);
    bytes[0] ^= 1;
    for (final patch in [
      {'payload': base64Encode(bytes)},
      {'record_id': uuid.v4()},
      {'deleted': true},
      {'operation_id': uuid.v4()},
    ]) {
      final corrupt = CipherRecord.fromJson({...packet.toJson(), ...patch});
      expect(() => crypto.decrypt(corrupt), throwsA(anything));
    }
  });
  test('错误密码不解锁，异常 KDF 参数不会触发巨额分配', () async {
    final other = await VaultCrypto.initialize();
    await expectLater(
      other.unlock(envelope, 'incorrect password'),
      throwsA(anything),
    );
    expect(other.unlocked, false);
    final bad = {
      ...envelope,
      'kdf': {...envelope['kdf'] as Map, 'memory': 1099511627776},
    };
    await expectLater(
      other.unlock(bad, password),
      throwsA(isA<FormatException>()),
    );
    expect(other.unlocked, false);
  });
  test('密钥包认证阻止服务器替换恢复包装或派生参数', () {
    final bad = jsonDecode(jsonEncode(envelope)) as Json;
    (bad['recovery'] as Map)['nonce'] = base64Encode(Uint8List(24));
    expect(() => crypto.verifyEnvelope(bad), throwsA(anything));
  });
  test('改主密码只重包密钥，旧密码失败，恢复码仍可用', () async {
    final packet = crypto.encrypt(Memo(title: 'password rotation'));
    final changed = await crypto.changePassword(
      envelope,
      'new-test-password-2026',
    );
    final other = await VaultCrypto.initialize();
    await expectLater(other.unlock(changed, password), throwsA(anything));
    await other.unlock(changed, 'new-test-password-2026');
    expect(other.decrypt(packet).title, 'password rotation');
    other.lock();
    await other.unlock(changed, recovery, recovery: true);
    expect(other.decrypt(packet).title, 'password rotation');
    other.lock();
  });
  test('备份整体认证并且不含明文', () {
    final packet = crypto.encrypt(Memo(title: 'backup-secret-sentinel'));
    final backup = crypto.encryptBackup(envelope, {
      'format': 1,
      'records': [packet.toJson()],
      'history': [],
    });
    expect(jsonEncode(backup), isNot(contains('backup-secret-sentinel')));
    final content = crypto.decryptBackup(backup);
    expect((content['records'] as List).length, 1);
    final bytes = base64Decode(backup['payload'] as String);
    bytes[3] ^= 8;
    expect(
      () => crypto.decryptBackup({...backup, 'payload': base64Encode(bytes)}),
      throwsA(anything),
    );
  });
  test('SQLite 持久队列重启后保留，业务字段不落明文', () {
    final directory = Directory.systemTemp.createTempSync('xingji-core-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}/vault.sqlite3';
    final memo = Memo(
      title: 'plain-sentinel-xingji-917',
      body: 'private-body-917',
      tags: ['private-tag-917'],
    );
    final store = LocalStore(path);
    try {
      store.setMeta('envelope', jsonEncode(envelope));
      store.saveLocal(crypto.encrypt(memo));
      store.checkpoint(store.get(memo.id)!.packet);
      store.saveLocal(crypto.encrypt(memo.edit({'body': 'updated-body-917'})));
      expect(store.pending().map((o) => o.baseRevision), [0, 1]);
    } finally {
      store.close();
    }
    final reopened = LocalStore(path);
    try {
      expect(reopened.pendingCount, 2);
      expect(
        crypto.decrypt(reopened.get(memo.id)!.packet).body,
        'updated-body-917',
      );
      expect(reopened.history(memo.id).length, 1);
    } finally {
      reopened.close();
    }
    final contents = latin1.decode(File(path).readAsBytesSync());
    for (final value in [
      'plain-sentinel-xingji-917',
      'private-body-917',
      'private-tag-917',
      'updated-body-917',
    ]) {
      expect(contents, isNot(contains(value)));
    }
  });
  test('SQLite 原子回滚不会推进游标', () {
    final store = LocalStore(':memory:');
    store.setMeta('cursor', '4');
    expect(
      () => store.transaction(() {
        store.setMeta('cursor', '5');
        throw StateError('test interruption');
      }),
      throwsStateError,
    );
    expect(store.cursor, 4);
    store.close();
  });
  test('已提交操作确认不会覆盖稍后的本地修改', () {
    final store = LocalStore(':memory:');
    final memo = Memo(title: 'v1');
    final a = crypto.encrypt(memo);
    store.saveLocal(a);
    final b = crypto.encrypt(memo.edit({'title': 'v2'}));
    store.saveLocal(b);
    store.acknowledge(a, 1);
    expect(store.pendingCount, 1);
    expect(crypto.decrypt(store.get(memo.id)!.packet).title, 'v2');
    expect(store.get(memo.id)!.serverRevision, 1);
    expect(store.get(memo.id)!.revision, 2);
    store.close();
  });
  test('DPAPI 包装可逆，篡改后拒绝解密', () {
    final raw = Uint8List.fromList(List.generate(32, (i) => i));
    final wrapped = Dpapi.protect(raw);
    expect(wrapped, isNot(orderedEquals(raw)));
    expect(Dpapi.unprotect(wrapped), orderedEquals(raw));
    wrapped[wrapped.length - 1] ^= 1;
    expect(() => Dpapi.unprotect(wrapped), throwsA(anything));
  }, skip: !Platform.isWindows);
  test('每日重复跨夏令时保持当地钟面时间', () {
    final ny = tz.getLocation('America/New_York');
    final due = tz.TZDateTime(ny, 2026, 3, 7, 9);
    final memo = Memo(
      title: 'DST',
      dueAt: due.toUtc(),
      timezone: ny.name,
      recurrence: 'daily',
    );
    final next = memo.complete(now: due.toUtc());
    final local = tz.TZDateTime.from(next.dueAt!, ny);
    expect(local.hour, 9);
    expect(local.day, 8);
    expect(next.dueAt!.difference(due.toUtc()).inHours, 23);
  });
  test('工作日跳过周末，重复完成与结束系列分离', () {
    final sh = tz.getLocation('Asia/Shanghai');
    final friday = tz.TZDateTime(sh, 2026, 10, 30, 15);
    final memo = Memo(
      title: 'weekday',
      dueAt: friday.toUtc(),
      recurrence: 'weekdays',
    );
    final next = memo.complete(now: friday.toUtc());
    expect(next.dueAt!.toLocal().weekday, DateTime.monday);
    expect(next.status, 'open');
    expect(next.completions, 1);
    expect(next.occurrence, isNot(memo.occurrence));
    final done = memo.complete(now: friday.toUtc(), stopSeries: true);
    expect(done.done, true);
    expect(done.recurrence, 'none');
  });
  test('事项级闹铃字段默认关闭，旧数据缺键兼容，编辑与重复周期继承', () {
    final memo = Memo(title: '闹铃兼容', dueAt: DateTime.utc(2030, 1, 1));
    expect(memo.forceAlarm, false);
    expect(memo.toJson()['force_alarm'], false);
    final legacy = {...memo.toJson()}..remove('force_alarm');
    expect(Memo.fromJson(legacy).forceAlarm, false);
    final armed = memo.edit({'force_alarm': true});
    expect(armed.forceAlarm, true);
    final decoded = Memo.fromJson(
      jsonDecode(jsonEncode(armed.toJson())) as Json,
    );
    expect(decoded.forceAlarm, true);
    expect(armed.edit({'title': '改名'}).forceAlarm, true);
    final recurring = Memo(
      title: '每日闹铃',
      dueAt: DateTime.now().toUtc().subtract(const Duration(hours: 1)),
      recurrence: 'daily',
      forceAlarm: true,
    );
    final next = recurring.complete();
    expect(next.forceAlarm, true);
    expect(next.done, false);
  });
}
