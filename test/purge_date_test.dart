import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xingji/core/dated_memos.dart';
import 'package:xingji/core/local_store.dart';
import 'package:xingji/core/models.dart';
import 'package:xingji/core/vault_crypto.dart';

void main() {
  late VaultCrypto crypto;
  late Json envelope;
  setUpAll(() async {
    crypto = await VaultCrypto.initialize();
    envelope = (await crypto.create('isolated-purge-test-passphrase')).envelope;
  });
  tearDownAll(() => crypto.lock());

  test('永久删除清除业务记录、历史、旧待发修改和提醒，只留下无内容标记', () {
    final store = LocalStore(':memory:');
    try {
      final memo = Memo(title: '待彻底移除的标题', body: '原始内容', tags: ['标签']);
      final original = crypto.encrypt(memo);
      store.saveLocal(original);
      store.saveLocal(
        crypto.encrypt(
          memo.edit({'deleted_at': DateTime.now().toIso8601String()}),
        ),
      );
      store.db.execute('INSERT INTO reminders VALUES(?,?,?,?,?,0)', [
        'reminder',
        memo.id,
        'generation',
        'occurrence',
        123,
      ]);
      final marker = crypto.encrypt(Memo.purgeMarker(memo.id));
      store.purgeLocal(marker);
      expect(store.get(memo.id), isNull);
      expect(store.history(memo.id), isEmpty);
      expect(store.pending(), isEmpty);
      expect(store.db.select('SELECT * FROM reminders'), isEmpty);
      expect(store.pendingCount, 1);
      final content = crypto.decrypt(store.purgeMarkers().single);
      expect(content.purged, true);
      expect(content.title, isEmpty);
      expect(content.body, isEmpty);
      expect(content.tags, isEmpty);
      expect(jsonEncode(store.snapshot()), isNot(contains(original.payload)));
    } finally {
      store.close();
    }
  });

  test('离线删除重启仍待同步，重复确认幂等，旧修改和旧远程数据不能复活', () {
    final directory = Directory.systemTemp.createTempSync('xingji-purge-');
    final path = '${directory.path}/vault.sqlite3';
    var store = LocalStore(path);
    try {
      final memo = Memo(title: '旧内容');
      final original = crypto.encrypt(memo);
      final marker = crypto.encrypt(Memo.purgeMarker(memo.id));
      store.saveLocal(original);
      store.db.execute('DROP TABLE purges');
      store.db.execute('PRAGMA user_version=1');
      store.close();
      store = LocalStore(path);
      expect(store.get(memo.id)!.packet.payload, original.payload);
      store.purgeLocal(marker);
      store.close();
      store = LocalStore(path);
      expect(store.pendingPurgeCount, 1);
      expect(
        store.purgeMarkers(pendingOnly: true).single.operationId,
        marker.operationId,
      );
      expect(() => store.saveLocal(original), throwsFormatException);
      store.applyPage([(packet: original, revision: 1)], 1);
      expect(store.all(), isEmpty);
      store.acceptPurge(marker, 2);
      store.acceptPurge(marker, 2);
      expect(store.pendingCount, 0);
      expect(store.purgeMarkers(), hasLength(1));
      expect(store.all(), isEmpty);
    } finally {
      store.close();
      for (final suffix in ['', '-wal', '-shm']) {
        final file = File('$path$suffix');
        if (file.existsSync()) file.deleteSync();
      }
      directory.deleteSync();
    }
  });

  test('收到认证删除标记时覆盖本地离线修改，备份恢复也保留删除保护', () {
    final store = LocalStore(':memory:'), restored = LocalStore(':memory:');
    try {
      final memo = Memo(title: '本地离线修改');
      final original = crypto.encrypt(memo);
      store.saveLocal(original);
      final marker = crypto.encrypt(Memo.purgeMarker(memo.id));
      expect(crypto.decrypt(marker).purged, true);
      store.applyPage(
        [(packet: marker, revision: 5)],
        9,
        purgedIds: {marker.operationId},
      );
      expect(store.pendingCount, 0);
      expect(store.cursor, 9);
      expect(store.get(memo.id), isNull);
      restored.restore(
        envelope,
        [original],
        [original],
        purges: store.purgeMarkers(),
      );
      expect(restored.all(), isEmpty);
      expect(restored.history(memo.id), isEmpty);
      expect(restored.pendingPurgeCount, 1);
      expect(() => restored.saveLocal(original), throwsFormatException);
    } finally {
      store.close();
      restored.close();
    }
  });

  test('删除标记必须认证且不能夹带原始内容', () {
    final marker = crypto.encrypt(Memo.purgeMarker(uuid.v4()));
    expect(
      () => crypto.decrypt(
        CipherRecord.fromJson({
          ...marker.toJson(),
          'payload': 'AAAAAAAAAAAAAAAAAAAAAA==',
        }),
      ),
      throwsA(anything),
    );
    final invalid = crypto.encrypt(
      Memo.purgeMarker(uuid.v4()).edit({'title': '不允许保留的内容'}),
    );
    expect(() => crypto.decrypt(invalid), throwsFormatException);
  });

  test('当天事项以未完成的安排日期和归档的实际完成日期分别判断', () {
    final today = DateTime(2026, 10, 29);
    final open = Memo(title: '当天安排', dueAt: DateTime(2026, 10, 29, 16).toUtc());
    final done = Memo(
      title: '昨天安排今天完成',
      dueAt: DateTime(2026, 10, 28, 10).toUtc(),
    ).complete(now: DateTime(2026, 10, 29, 9));
    final undatedDone = Memo(title: '没有时间也能按完成日期回看')
        .complete(now: DateTime(2026, 10, 29, 12));
    expect(matchesMemoDate(open, today, 'all', 'activity'), true);
    expect(matchesMemoDate(done, today, 'done', 'activity'), true);
    expect(matchesMemoDate(done, today, 'all', 'scheduled'), false);
    expect(matchesMemoDate(undatedDone, today, 'done', 'completed'), true);
    expect(matchesMemoDate(open, today, 'open', 'completed'), false);
  });

  test('未来安排、午夜边界、状态过滤及回收站排除正确', () {
    final day = DateTime(2026, 11, 1);
    final future = Memo(title: '未来', dueAt: DateTime(2026, 11, 1).toUtc());
    final end = Memo(
      title: '末尾',
      dueAt: DateTime(2026, 11, 1, 23, 59, 59).toUtc(),
    );
    final next = Memo(title: '下一天', dueAt: DateTime(2026, 11, 2).toUtc());
    expect(matchesMemoDate(future, day, 'open', 'activity'), true);
    expect(matchesMemoDate(end, day, 'all', 'scheduled'), true);
    expect(matchesMemoDate(next, day, 'all', 'activity'), false);
    expect(matchesMemoDate(future, day, 'done', 'activity'), false);
    expect(
      matchesMemoDate(
        future.edit({'deleted_at': DateTime.now().toIso8601String()}),
        day,
        'all',
        'activity',
      ),
      false,
    );
  });
}
