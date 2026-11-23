import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as timezone_data;
import 'package:xingji/core/app_controller.dart';
import 'package:xingji/core/local_store.dart';
import 'package:xingji/core/models.dart';
import 'package:xingji/core/vault_crypto.dart';
import 'package:xingji/platform/desktop_service.dart';
import 'package:xingji/ui/dialogs.dart';
import 'package:xingji/ui/mobile_workspace.dart';
import 'package:xingji/ui/onboarding.dart';
import 'package:xingji/ui/theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  timezone_data.initializeTimeZones();
  late LocalStore store;
  late AppController app;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() async {
    store = LocalStore(':memory:');
    app = AppController(
      store,
      await VaultCrypto.initialize(),
      'isolated-mobile',
    );
    messenger.setMockMethodCallHandler(
      DesktopService.channel,
      (call) async => switch (call.method) {
        'initialize' => {
          'allowed': true,
          'hotkey': false,
          'activation': '',
          'exact': false,
        },
        'notificationState' => {
          'allowed': true,
          'exact': false,
          'scheduled': 0,
          'delivered': <String>[],
        },
        _ => null,
      },
    );
    await app.initialize();
    await app.create('mobile-synthetic-passphrase', trust: false);
    app.recoveryCode = null;
  });
  tearDown(() async {
    if (app.unlocked) await app.lock();
    app.dispose();
    store.close();
    messenger.setMockMethodCallHandler(DesktopService.channel, null);
  });
  Future<void> mount(WidgetTester tester, {double width = 360}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 780);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpWidget(
      AnimatedBuilder(
        animation: app,
        builder: (context, _) => MaterialApp(
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [Locale('zh', 'CN')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          theme: xingjiTheme(dark: app.darkMode),
          home: app.unlocked ? MobileWorkspace(app: app) : VaultGate(app: app),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester) async {
    var finished = false;
    app.lock().then((_) => finished = true);
    for (var i = 0; i < 100 && !finished; i++) {
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    expect(finished, true);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }

  testWidgets('手机 360 宽新建、键盘避让、保存返回及返回键保存', (tester) async {
    await mount(tester);
    await tester.tap(find.text('新建备忘录'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('memo-title')), '手机保存测试');
    await tester.enterText(find.byKey(const Key('memo-body')), '正文在系统返回时也会保存');
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const Key('save-and-return')));
    await tester.pumpAndSettle();
    expect(find.text('已保存'), findsOneWidget);
    final memo = app.memos.single;
    expect(memo.body, '正文在系统返回时也会保存');
    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.tap(find.byKey(const Key('mobile-memos')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('mobile-row-${memo.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('edit-memo')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('memo-title')), '系统返回保存');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(app.selectedId, isNull);
    expect(app.memos.single.title, '系统返回保存');
    expect(tester.takeException(), isNull);
    await finish(tester);
  });

  testWidgets('日期导航与详情返回在窄屏保留完成日期筛选', (tester) async {
    final memo = Memo(
      title: '昨天完成的归档',
      status: 'done',
      completedAt: DateTime.now().subtract(const Duration(days: 1)),
    );
    await app.save(memo);
    app.select(null);
    await mount(tester, width: 320);
    await tester.tap(find.byKey(const Key('mobile-dates')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('date-previous')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('date-basis-completed')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('dated-row-${memo.id}')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('back-to-dates')), findsOneWidget);
    await tester.tap(find.byKey(const Key('mobile-back')));
    await tester.pumpAndSettle();
    expect(app.dateBasis, 'completed');
    expect(find.byKey(ValueKey('dated-row-${memo.id}')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await finish(tester);
  });

  testWidgets('320 宽历史预览取消不恢复，确认恢复且能找回恢复前版本', (tester) async {
    final memo = Memo(title: '旧标题', body: '这是完整旧正文', tags: ['工作']);
    await app.save(memo);
    app.saveVersion(memo.id);
    await app.save(memo.edit({'title': '新标题', 'body': '最新正文'}));
    app.saveVersion(memo.id);
    await mount(tester, width: 320);
    await tester.tap(find.byTooltip('修改历史'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('预览与恢复').last);
    await tester.pumpAndSettle();
    expect(find.text('版本预览'), findsOneWidget);
    expect(find.text('这是完整旧正文'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(app.memos.single.title, '新标题');
    await tester.tap(find.text('预览与恢复').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('恢复此版本'));
    await tester.pumpAndSettle();
    expect(app.memos.single.title, '旧标题');
    expect(
      store
          .history(memo.id)
          .map(app.crypto.decrypt)
          .any((m) => m.body == '最新正文'),
      true,
    );
    expect(tester.takeException(), isNull);
    await finish(tester);
  });

  testWidgets('手机回收站永久删除取消保留、确认入持久同步队列', (tester) async {
    final memo = Memo(title: '待清理的手机测试', deletedAt: DateTime.now());
    await app.save(memo);
    app.select(null);
    await mount(tester);
    await tester.tap(find.byKey(const Key('mobile-memos')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('memo-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('filter-option-trash')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('mobile-row-${memo.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('purge-memo')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(store.get(memo.id), isNotNull);
    await tester.tap(find.byKey(const Key('purge-memo')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-purge')));
    await tester.pumpAndSettle();
    expect(store.get(memo.id), isNull);
    expect(store.pendingPurgeCount, 1);
    expect(tester.takeException(), isNull);
    await finish(tester);
  });

  testWidgets('手机首页将当天事项放在首屏，保存提示不占据大块空间', (tester) async {
    final memo = Memo(
      title: '首屏事项',
      dueAt: DateTime.now().add(const Duration(minutes: 10)),
    );
    await app.save(memo);
    app.select(null);
    await mount(tester);
    final row = find.byKey(ValueKey('agenda-row-${memo.id}'));
    expect(row, findsOneWidget);
    expect(tester.getTopLeft(row).dy, lessThan(360));
    expect(find.text('查看今天的待办，或记下新的安排。'), findsNothing);
    expect(tester.takeException(), isNull);
    await finish(tester);
  });

  testWidgets('后台调用时钟授权需实际刷新确认，点击设置本身不算授权', (tester) async {
    var allowed = false;
    var requested = 0;
    store.setMeta('alarm_reminders', 'true');
    app.desktop.clockBackgroundAllowed = false;
    messenger.setMockMethodCallHandler(DesktopService.channel, (call) async {
      if (call.method == 'clockBackgroundSettings') requested++;
      if (call.method == 'notificationState') {
        return {
          'allowed': true,
          'exact': true,
          'clockBackgroundAllowed': allowed,
          'clockAvailable': true,
          'scheduled': 0,
          'delivered': <String>[],
        };
      }
      return null;
    });
    await mount(tester, width: 320);
    await tester.tap(find.byKey(const Key('mobile-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('数据库与同步'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('系统提醒'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('允许后台调用时钟'), 300);
    await tester.pumpAndSettle();
    await tester.tap(find.text('允许后台调用时钟'));
    await tester.pumpAndSettle();
    expect(requested, 1);
    expect(find.text('允许后台调用时钟'), findsOneWidget);
    allowed = true;
    await app.desktop.refreshState();
    await tester.pumpAndSettle();
    expect(find.text('允许后台调用时钟'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await finish(tester);
  });

  testWidgets('手机设置和连接弹窗适配 320 宽与软键盘', (tester) async {
    await mount(tester, width: 320);
    await tester.tap(find.byKey(const Key('mobile-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('配置连接'));
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    await tester.pumpAndSettle();
    expect(find.byType(ConnectionDialog), findsOneWidget);
    expect(tester.takeException(), isNull);
    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('取消'));
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('配置连接'), findsNothing);
    await app.toggleTheme();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await finish(tester);
  });

  testWidgets('30 秒事项测试区分登记、系统时钟请求与实际播放，不隐藏失败', (tester) async {
    var requested = 0;
    final testAt = DateTime.now()
        .add(const Duration(seconds: 30))
        .millisecondsSinceEpoch;
    Map<String, Object> receipt = {};
    store.setMeta('alarm_reminders', 'true');
    messenger.setMockMethodCallHandler(DesktopService.channel, (call) async {
      if (call.method == 'scheduleTimedTest') {
        requested++;
        receipt = {
          'at': testAt,
          'stage': 'schedule_submitted',
          'mode': 'alarm_clock',
        };
      }
      if (call.method == 'notificationState') {
        return {
          'allowed': true,
          'exact': true,
          'fullScreen': true,
          'scheduled': 1,
          'delivered': <String>[],
          'timedTest': receipt,
        };
      }
      return null;
    });
    await mount(tester, width: 320);
    await tester.tap(find.byKey(const Key('mobile-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('数据库与同步'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('系统提醒'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('30 秒后事项测试'), 300);
    await tester.pumpAndSettle();
    await tester.tap(find.text('30 秒后事项测试'));
    await tester.pumpAndSettle();
    expect(requested, 1);
    expect(find.textContaining('播放：未开始'), findsOneWidget);
    expect(find.textContaining('播放：已开始'), findsNothing);
    receipt = {
      ...receipt,
      'receivedAt': testAt,
      'clockRequestedAt': testAt + 200,
      'stage': 'clock_reminder_sent',
    };
    await app.desktop.refreshState();
    await tester.pumpAndSettle();
    expect(find.textContaining('系统时钟：请求已发出'), findsOneWidget);
    expect(find.textContaining('播放：已开始'), findsNothing);
    expect(find.textContaining('交接偏差 0.2 秒'), findsOneWidget);
    receipt = {
      'at': testAt,
      'mode': 'alarm_clock',
      'receivedAt': testAt,
      'stage': 'notification_posted',
      'clockReason': 'background_permission_missing',
    };
    await app.desktop.refreshState();
    await tester.pumpAndSettle();
    expect(find.textContaining('未允许后台调用系统时钟'), findsOneWidget);
    expect(find.textContaining('铃声已停止'), findsNothing);
    receipt = {
      'at': testAt,
      'mode': 'alarm_clock',
      'receivedAt': testAt,
      'stage': 'notification_posted',
      'route': 'screen_on_notification',
    };
    await app.desktop.refreshState();
    await tester.pumpAndSettle();
    expect(find.textContaining('亮屏通知：已发出'), findsOneWidget);
    expect(find.textContaining('已降级为普通通知'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await finish(tester);
  });

  testWidgets('系统时钟测试独立于提醒权限，区分发起与手动结果并复制精简诊断', (tester) async {
    var launches = 0;
    var scheduled = 0;
    String? copied;
    Map<String, Object> receipt = {};
    store.setMeta('notifications', 'false');
    store.setMeta('alarm_reminders', 'false');
    final report = jsonEncode({
      'systemClockTest': {'status': 'request_sent', 'userResult': 'silent'},
      'events': List.generate(10, (i) => {'stage': 'fixture', 'time': i}),
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = call.arguments['text'] as String;
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    messenger.setMockMethodCallHandler(DesktopService.channel, (call) async {
      if (call.method == 'testSystemClock') {
        launches++;
        expect(call.arguments['scenario'], 'screen_off');
        receipt = {
          'id': 'anonymous-fixture',
          'requestedAt': DateTime.now().millisecondsSinceEpoch,
          'scenario': 'screen_off',
          'status': 'request_sent',
        };
        return receipt;
      }
      if (call.method == 'scheduleTimedTest') scheduled++;
      if (call.method == 'reportSystemClockTest') {
        expect(call.arguments['id'], 'anonymous-fixture');
        receipt = {
          ...receipt,
          'userResult': call.arguments['outcome'] as String,
        };
        return receipt;
      }
      if (call.method == 'reminderDiagnostics') return report;
      if (call.method == 'notificationState') {
        return {'allowed': false, 'exact': false, 'systemClockTest': receipt};
      }
      return null;
    });
    await mount(tester, width: 320);
    await tester.tap(find.byKey(const Key('mobile-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('数据库与同步'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('系统提醒'));
    await tester.pumpAndSettle();
    final scenario = find.byKey(const Key('clock-scenario-screen_off'));
    await tester.ensureVisible(scenario);
    await tester.tap(scenario);
    await tester.pumpAndSettle();
    final start = find.byKey(const Key('system-clock-test'));
    await tester.ensureVisible(start);
    await tester.tap(start);
    await tester.pumpAndSettle();
    expect(launches, 1);
    expect(scheduled, 0);
    expect(tester.widget<FilledButton>(start).onPressed, isNull);
    expect(find.textContaining('实际响铃待你确认'), findsOneWidget);
    expect(find.textContaining('你的反馈：'), findsNothing);
    final outcome = find.byKey(const Key('clock-result-silent'));
    await tester.ensureVisible(outcome);
    await tester.tap(outcome);
    await tester.pumpAndSettle();
    expect(find.text('你的反馈：没有响铃（手动记录）'), findsOneWidget);
    final copy = find.byKey(const Key('copy-reminder-diagnostics'));
    await tester.ensureVisible(copy);
    await tester.tap(copy);
    await tester.pumpAndSettle();
    expect(copied, report);
    expect((jsonDecode(copied!) as Map)['events'], hasLength(10));
    expect(app.memos, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await finish(tester);
  });

  testWidgets('系统时钟调用失败显示原因，不能填写成功回执', (tester) async {
    Map<String, Object> receipt = {};
    messenger.setMockMethodCallHandler(DesktopService.channel, (call) async {
      if (call.method == 'notificationState') {
        return {'systemClockTest': receipt};
      }
      return null;
    });
    await mount(tester, width: 320);
    await tester.tap(find.byKey(const Key('mobile-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('数据库与同步'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('系统提醒'));
    await tester.pumpAndSettle();
    for (final entry in {
      'clock_handler_missing': '没有找到支持倒计时',
      'clock_permission_denied': '系统拒绝了时钟调用',
      'clock_foreground_required': '请回到星记设置页面',
      'clock_launch_failed': '时钟调用失败',
    }.entries) {
      receipt = {'id': 'fixture', 'status': entry.key};
      await app.desktop.refreshState();
      await tester.pumpAndSettle();
      expect(find.textContaining(entry.value), findsOneWidget);
      expect(find.byKey(const Key('clock-result-rang')), findsNothing);
      expect(find.textContaining('实际响铃待你确认'), findsNothing);
    }
    expect(tester.takeException(), isNull);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await finish(tester);
  });
}
