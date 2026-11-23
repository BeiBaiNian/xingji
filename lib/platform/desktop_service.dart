import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/services.dart';

import '../core/local_store.dart';
import '../core/models.dart';

class DesktopService {
  DesktopService(this.store, this.onState);
  final LocalStore store;
  final void Function() onState;
  static const channel = MethodChannel('xingji/desktop');
  void Function(String)? onEvent;
  bool ready = false, allowed = false, hotkey = false;
  bool exact = true;
  bool fullScreen = true;
  int alarmVolume = 0;
  bool notificationsAllowed = false, alarmChannelAllowed = true;
  bool alarmChannelHighPriority = true;
  bool batteryOptimized = false;
  String manufacturer = '';
  int registrationFailures = 0;
  int inexactSchedules = 0;
  DateTime? nextReminderAt;
  Map<String, dynamic> timedTest = {};
  Map<String, dynamic> systemClockTest = {};
  Map<String, dynamic> clockReminder = {};
  bool clockBackgroundAllowed = false, clockAvailable = false;
  bool screenOnAllowed = true,
      screenOnHighPriority = true,
      screenOnSound = true;
  bool get alarmMode =>
      Platform.isAndroid && store.getMeta('alarm_reminders') == 'true';
  // Clock-based readiness also matters when only per-memo force alarms exist.
  bool get alarmNeeded =>
      alarmMode || store.getMeta('force_alarm_items') == 'true';
  String status = '正在检查系统通知';
  String initialActivation = '';
  String _fingerprint = '';
  Future<void> _queue = Future.value();
  Future<void> waitForPending() => _queue;

  bool? _clipboardHasImage;

  Future<bool> hasClipboardImage() async {
    final cached = _clipboardHasImage;
    if (cached == true) return true;
    try {
      // A quick copy and paste can precede WM_CLIPBOARDUPDATE. Check formats
      // before handing a previously empty clipboard back to the text field.
      final status = await channel.invokeMapMethod<String, bool>(
        'clipboardImageStatus',
      );
      final available = status?['hasImage'] == true;
      if (_clipboardHasImage == cached) {
        _clipboardHasImage = status?['listening'] == true ? available : null;
      }
      return _clipboardHasImage ?? available;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> initialize() async {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'clipboardImageChanged' &&
          defaultTargetPlatform == TargetPlatform.windows) {
        _clipboardHasImage = call.arguments as bool;
      } else if (call.method == 'event') {
        onEvent?.call(call.arguments as String);
      }
    });
    if (defaultTargetPlatform == TargetPlatform.windows) {
      await hasClipboardImage();
    }
    try {
      final result = (await channel.invokeMapMethod<String, dynamic>(
        'initialize',
      ))!;
      _readState(result);
      hotkey = result['hotkey'] == true;
      initialActivation = result['activation'] as String? ?? '';
      ready = true;
      _updateStatus(result);
    } on PlatformException catch (e) {
      ready = false;
      status = e.details == -2147024891
          ? '提醒未就绪：无权登记系统提醒，请从正式安装目录启动（见安装说明）'
          : '提醒未就绪：${e.message ?? '系统初始化失败'}';
    } catch (_) {
      ready = false;
      status = '系统提醒未就绪，请在设置中重试';
    }
    onState();
  }

  static String xmlEscape(String text) =>
      const HtmlEscape(HtmlEscapeMode.element)
          .convert(text)
          .replaceAll('"', '&quot;')
          .replaceAll("'", '&apos;');

  static String toastXml({
    required String title,
    required String body,
    String uri = 'xingji://open',
    bool actions = false,
  }) {
    final parsed = Uri.parse(uri);
    String action(String name, [int? minutes]) => xmlEscape(
      parsed
          .replace(
            host: name,
            queryParameters: {
              ...parsed.queryParameters,
              if (minutes != null) 'minutes': '$minutes',
            },
          )
          .toString(),
    );
    return '<toast activationType="protocol" launch="${xmlEscape(uri)}"><visual><binding template="ToastGeneric">'
        '<text>${xmlEscape(title)}</text><text>${xmlEscape(body)}</text></binding></visual>'
        '${actions ? '<actions><action content="完成本次" activationType="protocol" arguments="${action("complete")}"/>'
                  '<action content="稍后 10 分钟" activationType="protocol" arguments="${action("snooze", 10)}"/></actions>' : ''}'
        '<audio src="ms-winsoundevent:Notification.Reminder"/></toast>';
  }

  Future<void> test({bool alarm = false}) async {
    if (!ready) await initialize();
    await channel.invokeMethod('showNotification', {
      'id': 'test',
      'alarm': alarm,
      'title': '星记 · 提醒测试',
      'body': '看到这条通知，说明系统通知已送达。',
      'uri': 'xingji://open',
      'xml': toastXml(title: '星记 · 提醒测试', body: '看到这条通知，说明系统通知已送达。'),
    });
    await refreshState();
  }

  Future<void> refreshState() async {
    try {
      final result = (await channel.invokeMapMethod<String, dynamic>(
        'notificationState',
      ))!;
      _readState(result);
      _updateStatus(result);
    } catch (_) {
      status = '无法读取提醒状态，请重试';
    }
    onState();
  }

  void _readState(Map<String, dynamic> result) {
    allowed = result['allowed'] == true;
    notificationsAllowed =
        result['notificationsAllowed'] == true ||
        !result.containsKey('notificationsAllowed') && allowed;
    exact = result['exact'] != false;
    fullScreen = result['fullScreen'] != false;
    alarmChannelAllowed = result['alarmChannelAllowed'] != false;
    alarmChannelHighPriority = result['alarmChannelHighPriority'] != false;
    alarmVolume = result['alarmVolume'] as int? ?? 0;
    registrationFailures = result['registrationFailures'] as int? ?? 0;
    inexactSchedules = result['inexactSchedules'] as int? ?? 0;
    manufacturer = result['manufacturer'] as String? ?? '';
    batteryOptimized = result['batteryOptimized'] == true;
    final at = result['nextAt'] as int? ?? 0;
    nextReminderAt = at > 0 ? DateTime.fromMillisecondsSinceEpoch(at) : null;
    timedTest = Map<String, dynamic>.from(result['timedTest'] as Map? ?? {});
    systemClockTest = Map<String, dynamic>.from(
      result['systemClockTest'] as Map? ?? {},
    );
    clockReminder = Map<String, dynamic>.from(
      result['clockReminder'] as Map? ?? {},
    );
    clockBackgroundAllowed = result['clockBackgroundAllowed'] == true;
    clockAvailable = result['clockAvailable'] == true;
    screenOnAllowed = result['screenOnAllowed'] != false;
    screenOnHighPriority = result['screenOnHighPriority'] != false;
    screenOnSound = result['screenOnSound'] != false;
  }

  void _updateStatus(Map<String, dynamic> result) {
    if (Platform.isAndroid) {
      final reasons = <String>[
        if (store.getMeta('notifications') == 'false') '本机提醒已暂停',
        if (!notificationsAllowed) '系统通知已关闭',
        if (alarmMode && !screenOnAllowed) '亮屏提醒通知已关闭',
        if (alarmMode && screenOnAllowed && !screenOnHighPriority)
          '亮屏提醒未允许顶部横幅',
        if (alarmMode && !screenOnSound) '亮屏提醒提示音已关闭',
        if (alarmNeeded && !clockAvailable) '未找到支持倒计时的时钟',
        if (alarmNeeded && !clockBackgroundAllowed) '未允许后台调用系统时钟',
        if (!alarmMode && !allowed) '普通提醒渠道已关闭',
        if (!exact) '未允许准时提醒',
        if (alarmNeeded && alarmVolume == 0) '闹钟音量为零',
        if (registrationFailures > 0) '$registrationFailures 项系统登记失败',
        if (exact && inexactSchedules > 0) '$inexactSchedules 项已降级为非精确排程',
      ];
      status = reasons.isNotEmpty
          ? '${alarmNeeded ? '闹铃未就绪' : '提醒未就绪'}：${reasons.join('；')}'
          : '${alarmMode
                ? '息屏用系统时钟，亮屏用通知提示音'
                : alarmNeeded
                ? '闹铃事项到点调用系统时钟，其余事项用通知'
                : '系统提醒已就绪'} · ${result['scheduled'] ?? 0} 项本机计划';
    } else {
      status = allowed
          ? exact
                ? '系统提醒已就绪 · ${result['scheduled']} 项待发'
                : '非精确提醒 · 请在设置中允许“闹钟和提醒”'
          : '系统通知已关闭，请在系统设置中开启';
    }
  }

  Future<void> scheduleTimedTest() async {
    await channel.invokeMethod('scheduleTimedTest');
    await refreshState();
  }

  Future<void> clockBackgroundSettings() async {
    await channel.invokeMethod('clockBackgroundSettings');
    await refreshState();
  }

  Future<void> screenOnNotificationSettings() =>
      channel.invokeMethod('screenOnNotificationSettings');

  static String clockFailureText(Object? reason) => switch (reason) {
    'background_permission_missing' => '未允许后台调用系统时钟',
    'exact_permission_missing' => '未允许准时提醒',
    'clock_handler_missing' => '未找到支持倒计时的时钟',
    'clock_choice_required' => '请先用 10 秒测试选择默认时钟',
    'clock_launch_denied' => '系统拒绝了时钟调用',
    'clock_launch_failed' => '时钟调用失败',
    _ => '尚未确认时钟启动，请复制诊断',
  };

  Future<void> testSystemClock(String scenario) async {
    systemClockTest = Map<String, dynamic>.from(
      await channel.invokeMapMethod<String, dynamic>('testSystemClock', {
            'scenario': scenario,
          }) ??
          {},
    );
    onState();
  }

  Future<void> reportSystemClockTest(String id, String outcome) async {
    systemClockTest = Map<String, dynamic>.from(
      await channel.invokeMapMethod<String, dynamic>('reportSystemClockTest', {
            'id': id,
            'outcome': outcome,
          }) ??
          {},
    );
    onState();
  }

  Future<void> cancelTimedTest() async {
    await channel.invokeMethod('cancelTimedTest');
    await refreshState();
  }

  Future<String> reminderDiagnostics() async =>
      await channel.invokeMethod<String>('reminderDiagnostics') ?? '';

  Future<void> reconcile(
    List<({Memo memo, CipherRecord packet})> records, {
    required bool enabled,
    required bool showTitles,
    required bool quiet,
    bool force = false,
  }) {
    _queue = _queue
        .then(
          (_) => _reconcile(
            records,
            enabled: enabled,
            showTitles: showTitles,
            quiet: quiet,
            force: force,
          ),
        )
        .catchError((Object _) {
          status = '提醒排程失败，任务已保存，请在设置中重试';
          onState();
        });
    return _queue;
  }

  Future<void> _reconcile(
    List<({Memo memo, CipherRecord packet})> records, {
    required bool enabled,
    required bool showTitles,
    required bool quiet,
    required bool force,
  }) async {
    if (!ready) {
      if (force) await initialize();
      if (!ready) return;
    }
    // Persisted before the fingerprint short-circuit so readiness survives restarts.
    final forceItems =
        Platform.isAndroid &&
        records.any((r) {
          final m = r.memo;
          return m.forceAlarm && !m.done && !m.deleted && m.dueAt != null;
        });
    store.setMeta('force_alarm_items', forceItems.toString());
    final fingerprint = jsonEncode([
      enabled,
      showTitles,
      quiet,
      alarmMode,
      records.map((e) => e.packet.operationId).toList()..sort(),
    ]);
    if (!force && _fingerprint == fingerprint) return;
    final now = DateTime.now();
    final old = {
      for (final row in store.db.select('SELECT * FROM reminders'))
        row['id'] as String: row,
    };
    final state = (await channel.invokeMapMethod<String, dynamic>(
      'notificationState',
    ))!;
    final delivered = (state['delivered'] as List? ?? [])
        .cast<String>()
        .toSet();
    final next = <Json>[];
    final schedule = <Json>[];
    final overdueIds = <String>{};
    if (enabled) {
      for (final record in records) {
        final memo = record.memo;
        if (memo.done || memo.deleted || memo.dueAt == null) continue;
        // Per-memo force alarms bypass the global alarm toggle, quiet hours and
        // the screen-on notification route. Other platforms keep current behavior.
        final forceAlarm = Platform.isAndroid && memo.forceAlarm;
        final times = memo.snoozedUntil != null
            ? [memo.snoozedUntil!]
            : memo.reminderOffsets
                  .toSet()
                  .map(
                    (offset) => memo.dueAt!.subtract(Duration(minutes: offset)),
                  )
                  .toList();
        for (var index = 0; index < times.length; index++) {
          var fire = times[index].toLocal();
          if (quiet && !forceAlarm && (fire.hour >= 22 || fire.hour < 8)) {
            fire = DateTime(
              fire.year,
              fire.month,
              fire.day + (fire.hour >= 22 ? 1 : 0),
              8,
            );
          }
          final id =
              '${record.packet.operationId.replaceAll('-', '').substring(0, 12)}$index';
          final previous = old[id];
          var handled = previous?['handled'] as int? ?? 0;
          if (fire.isAfter(now)) {
            final uri = Uri(
              scheme: 'xingji',
              host: 'open',
              queryParameters: {
                'id': memo.id,
                'occurrence': memo.occurrence,
                'generation': record.packet.operationId,
              },
            ).toString();
            schedule.add({
              'id': id,
              'at': fire.millisecondsSinceEpoch,
              'title': showTitles ? memo.title : '星记 · 有一项备忘录到期',
              'body': '打开星记，解锁后查看详情。',
              'uri': uri,
              'actions': true,
              'alarm': alarmMode || forceAlarm,
              'systemClock': alarmMode || forceAlarm,
              'forceAlarm': forceAlarm,
              'xml': toastXml(
                title: showTitles ? memo.title : '星记 · 有一项备忘录到期',
                body: '打开星记，解锁后查看详情。',
                uri: uri,
                actions: true,
              ),
            });
          } else {
            if (delivered.contains(id)) handled = 1;
            if (handled == 0 &&
                (previous == null || now.difference(fire).inMinutes >= 5)) {
              overdueIds.add(memo.id);
              handled = 1;
            }
          }
          next.add({
            'id': id,
            'record_id': memo.id,
            'generation': record.packet.operationId,
            'occurrence': memo.occurrence,
            'fire_at': fire.millisecondsSinceEpoch,
            'handled': handled,
          });
        }
      }
    }
    schedule.sort((a, b) => (a['at'] as int).compareTo(b['at'] as int));
    final limit = Platform.isAndroid ? 480 : 512;
    final bounded = schedule.take(limit).toList();
    final activeIds = next.map((r) => r['id']).toSet();
    await channel.invokeMethod('replaceSchedules', {
      'alarmMode': enabled && alarmNeeded,
      'items': bounded,
      'activeIds': activeIds.toList(),
      'removeIds': old.keys.where((id) => !activeIds.contains(id)).toList(),
    });
    if (overdueIds.isNotEmpty) {
      await channel.invokeMethod('showNotification', {
        'id': 'overdue',
        'title': '星记 · 逾期提醒',
        'body': '有 ${overdueIds.length} 项备忘录需要处理，打开星记查看。',
        'uri': 'xingji://open',
        'xml': toastXml(
          title: '星记 · 逾期提醒',
          body: '有 ${overdueIds.length} 项备忘录需要处理，打开星记查看。',
        ),
      });
    }
    store.transaction(() {
      store.db.execute('DELETE FROM reminders');
      for (final row in next) {
        store.db.execute(
          'INSERT INTO reminders(id,record_id,generation,occurrence,fire_at,handled) VALUES (?,?,?,?,?,?)',
          [
            row['id'],
            row['record_id'],
            row['generation'],
            row['occurrence'],
            row['fire_at'],
            row['handled'],
          ],
        );
      }
    });
    _fingerprint = fingerprint;
    await refreshState();
    if (!enabled) status = '本机提醒已暂停';
    if (schedule.length > limit) status += ' · 仅安排最近 $limit 项，运行时自动补排';
    onState();
  }

  Future<void> show() => channel.invokeMethod('show');
  Future<void> setTheme(bool dark) async {
    try {
      await channel.invokeMethod('theme', {'dark': dark});
    } catch (_) {
      /* Older native runners use their system titlebar theme. */
    }
  }

  Future<void> hide() => channel.invokeMethod('hide');
  Future<void> exit() => channel.invokeMethod('exit');
  Future<void> setStartup(bool enabled) =>
      channel.invokeMethod('startup', {'enabled': enabled});
  Future<void> openNotificationSettings() =>
      channel.invokeMethod('notificationSettings');
  Future<void> requestPermissions() async {
    await channel.invokeMethod('requestNotifications');
    await refreshState();
  }

  Future<void> exactSettings() => channel.invokeMethod('exactSettings');
  Future<void> alarmSoundSettings() =>
      channel.invokeMethod('alarmSoundSettings');
  Future<void> fullScreenSettings() =>
      channel.invokeMethod('fullScreenSettings');
  Future<void> alarmChannelSettings() =>
      channel.invokeMethod('alarmChannelSettings');
  Future<void> appSettings() => channel.invokeMethod('appSettings');
}
