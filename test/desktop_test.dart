import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as timezone_data;
import 'package:xingji/core/app_controller.dart';
import 'package:xingji/core/local_store.dart';
import 'package:xingji/core/models.dart';
import 'package:xingji/core/vault_crypto.dart';
import 'package:xingji/platform/desktop_service.dart';
import 'package:xingji/ui/theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  timezone_data.initializeTimeZones();
  late LocalStore store;
  late VaultCrypto crypto;
  late AppController app;
  var shown = 0;
  var replacements = 0;
  var darkTitlebar = false;
  List<String> scheduled = [];
  List<dynamic> scheduledItems = [];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() async {
    store = LocalStore(':memory:');
    crypto = await VaultCrypto.initialize();
    app = AppController(store, crypto, 'isolated-unit-test');
    shown = 0;
    replacements = 0;
    scheduled = [];
    scheduledItems = [];
    messenger.setMockMethodCallHandler(DesktopService.channel, (call) async {
      switch (call.method) {
        case 'initialize':
          return {'allowed': true, 'hotkey': true, 'activation': ''};
        case 'notificationState':
          return {
            'allowed': true,
            'scheduled': scheduled.length,
            'ids': scheduled,
            'delivered': <String>[],
          };
        case 'replaceSchedules':
          replacements++;
          scheduledItems = (call.arguments as Map)['items'] as List;
          scheduled = scheduledItems.map((r) => r['id'] as String).toList();
          return scheduled.length;
        case 'showNotification':
          shown++;
          return null;
        case 'theme':
          darkTitlebar = (call.arguments as Map)['dark'] as bool;
          return null;
        default:
          return null;
      }
    });
    await app.initialize();
    await app.create('unit-desktop-passphrase', trust: false);
    app.recoveryCode = null;
    await app.schedule(force: true);
  });
  tearDown(() async {
    await app.lock();
    app.dispose();
    store.db.close();
    messenger.setMockMethodCallHandler(DesktopService.channel, null);
  });

  test('主题切换保存偏好，并同步原生标题栏；两种配色均保持文字对比度', () async {
    expect(app.darkMode, false);
    await app.toggleTheme();
    expect(store.getMeta('appearance'), 'dark');
    expect(darkTitlebar, true);
    await app.toggleTheme();
    expect(store.getMeta('appearance'), 'light');
    expect(darkTitlebar, false);
    for (final dark in [false, true]) {
      final theme = xingjiTheme(dark: dark);
      final p = theme.extension<XingjiColors>()!;
      double contrast(Color a, Color b) {
        final values = [a.computeLuminance(), b.computeLuminance()]..sort();
        return (values.last + .05) / (values.first + .05);
      }

      expect(contrast(theme.colorScheme.onSurface, p.panel), greaterThan(4.5));
      expect(contrast(p.muted, p.panel), greaterThan(4.5));
    }
  });

  test('提醒只在内容变化时重排，完成撤销；旧通知不能完成新的重复任务', () async {
    final memo = Memo(
      title: '重复提醒',
      dueAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      recurrence: 'daily',
    );
    await app.save(memo);
    await app.schedule();
    expect(scheduled.length, 1);
    final original = store.get(memo.id)!.packet;
    final calls = replacements;
    await app.schedule();
    expect(replacements, calls);
    final uri = Uri(
      scheme: 'xingji',
      host: 'complete',
      queryParameters: {
        'id': memo.id,
        'occurrence': memo.occurrence,
        'generation': original.operationId,
      },
    ).toString();
    await app.handleEvent(uri);
    final next = app.memos.firstWhere((m) => m.id == memo.id);
    expect(next.completions, 1);
    final archive = app.memos.singleWhere((m) => m.done);
    expect(archive.body, memo.body);
    expect(archive.dueAt, memo.dueAt);
    expect(archive.deleted, false);
    expect(archive.recurrence, 'none');
    await app.handleEvent(uri);
    expect(app.memos.firstWhere((m) => m.id == memo.id).completions, 1);
    expect(app.memos.where((m) => m.done), hasLength(1));
    expect(app.message, contains('过期'));
    await app.save(next.complete(stopSeries: true));
    await app.schedule(force: true);
    expect(scheduled, isEmpty);
  });

  test('到期不足送达窗口时保留补偿资格，超过窗口后只补报一次', () async {
    final memo = Memo(
      title: '离线到期',
      dueAt: DateTime.now().toUtc().subtract(const Duration(minutes: 1)),
    );
    final packet = crypto.encrypt(memo);
    final id = '${packet.operationId.replaceAll('-', '').substring(0, 12)}0';
    store.db.execute(
      'INSERT INTO reminders(id,record_id,generation,occurrence,fire_at,handled) VALUES (?,?,?,?,?,0)',
      [
        id,
        memo.id,
        packet.operationId,
        memo.occurrence,
        memo.dueAt!.millisecondsSinceEpoch,
      ],
    );
    await app.desktop.reconcile(
      [(memo: memo, packet: packet)],
      enabled: true,
      showTitles: false,
      quiet: false,
      force: true,
    );
    expect(shown, 0);
    expect(
      store.db.select('SELECT handled FROM reminders').single['handled'],
      0,
    );
    final old = memo.edit({
      'due_at_utc': DateTime.now()
          .toUtc()
          .subtract(const Duration(minutes: 6))
          .toIso8601String(),
    });
    await app.desktop.reconcile(
      [(memo: old, packet: packet)],
      enabled: true,
      showTitles: false,
      quiet: false,
      force: true,
    );
    expect(shown, 1);
    await app.desktop.reconcile(
      [(memo: old, packet: packet)],
      enabled: true,
      showTitles: false,
      quiet: false,
      force: true,
    );
    expect(shown, 1);
  });

  test('距离到期不足两秒仍提交排程，不能在同步时提前取消', () async {
    final memo = Memo(
      title: '临界点虚构事项',
      dueAt: DateTime.now().toUtc().add(const Duration(milliseconds: 1900)),
    );
    final packet = crypto.encrypt(memo);
    await app.desktop.reconcile(
      [(memo: memo, packet: packet)],
      enabled: true,
      showTitles: false,
      quiet: false,
      force: true,
    );
    expect(scheduled, hasLength(1));
    expect(shown, 0);
  });

  test('非 Android 主机上事项级闹铃字段不改变排程与夜间顺延', () async {
    final now = DateTime.now();
    final memo = Memo(
      title: '跨平台闹铃字段',
      dueAt: DateTime(now.year, now.month, now.day + 1, 23, 30).toUtc(),
      forceAlarm: true,
    );
    await app.save(memo);
    await app.desktop.reconcile(
      [(memo: memo, packet: store.get(memo.id)!.packet)],
      enabled: true,
      showTitles: false,
      quiet: true,
      force: true,
    );
    expect(scheduledItems, hasLength(1));
    final item = scheduledItems.single as Map;
    expect(item['alarm'], false);
    expect(item['systemClock'], false);
    expect(item['forceAlarm'], false);
    expect(
      item['at'],
      DateTime(now.year, now.month, now.day + 2, 8).millisecondsSinceEpoch,
    );
    expect(store.getMeta('force_alarm_items'), 'false');
    expect(app.hasForceAlarmMemos, true);
    await app.toggleDone(memo);
    expect(app.hasForceAlarmMemos, false);
  });

  test('缓存不能掩盖同一操作 ID 的密文篡改', () async {
    final memo = Memo(title: '保留正常副本');
    await app.save(memo);
    await app.schedule();
    final packet = store.get(memo.id)!.packet;
    final bytes = base64Decode(packet.payload)..[0] ^= 1;
    final forged = {...packet.toJson(), 'payload': base64Encode(bytes)};
    store.db.execute('UPDATE records SET packet=? WHERE id=?', [
      jsonEncode(forged),
      memo.id,
    ]);
    app.sync.onChanged();
    expect(app.memos.single.title, memo.title);
    expect(app.message, contains('无法认证'));
  });
}
