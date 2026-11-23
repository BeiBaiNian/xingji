import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_controller.dart';
import '../core/sync_engine.dart';
import '../platform/desktop_service.dart';
import 'dialogs.dart';
import 'system_clock_test_panel.dart';
import 'theme.dart';

class MobileSettings extends StatefulWidget {
  const MobileSettings({super.key, required this.app});
  final AppController app;
  @override
  State<MobileSettings> createState() => _MobileSettingsState();
}

class _MobileSettingsState extends State<MobileSettings> {
  AppController get app => widget.app;
  bool busy = false;
  Timer? _testRefresh;
  @override
  void initState() {
    super.initState();
    _watchTest();
  }

  void _watchTest() {
    _testRefresh?.cancel();
    if (app.desktop.timedTest['at'] == null) return;
    _testRefresh = Timer.periodic(const Duration(seconds: 2), (_) {
      final at = app.desktop.timedTest['at'] as int?;
      if (at != null && DateTime.now().millisecondsSinceEpoch < at + 90000) {
        unawaited(app.desktop.refreshState());
      } else {
        _testRefresh?.cancel();
      }
    });
  }

  @override
  void dispose() {
    _testRefresh?.cancel();
    super.dispose();
  }

  String timeOf(int at) => MaterialLocalizations.of(context).formatTimeOfDay(
    TimeOfDay.fromDateTime(DateTime.fromMillisecondsSinceEpoch(at)),
    alwaysUse24HourFormat: true,
  );

  String get testStatus {
    final result = app.desktop.timedTest;
    final at = result['at'] as int?;
    if (at == null) return '';
    final submitted = result['mode'] != 'failed';
    final received = result['receivedAt'] as int?;
    final started = result['startedAt'] as int?;
    final clockRequested = result['clockRequestedAt'] as int?;
    final screenOn = result['route'] == 'screen_on_notification';
    final stage = result['stage'];
    final snoozed = result['reason'] == 'snoozed' && started == null;
    return '事项链路测试 ${timeOf(at)}\n'
        '排程：${submitted
            ? result['mode'] == 'inexact'
                  ? '非精确提交'
                  : '已提交'
            : '登记失败'} · 触发：${received != null ? '已收到' : '等待'} · '
        '${screenOn
            ? '亮屏通知：${stage == 'notification_posted'
                  ? '已发出'
                  : stage == 'notification_blocked'
                  ? '被系统设置阻止'
                  : '等待'}'
            : clockRequested != null
            ? '系统时钟：请求已发出，实际响铃待确认'
            : '播放：${started != null ? '已开始' : '未开始'}'}'
        '${clockRequested != null ? '（交接偏差 ${((clockRequested - at) / 1000).toStringAsFixed(1)} 秒）' : ''}'
        '${started != null ? '（偏差 ${((started - at) / 1000).toStringAsFixed(1)} 秒）' : ''}'
        '${stage == 'test_cancelled' ? '\n测试已取消' : ''}'
        '${stage == 'notification_posted' && !screenOn ? '\n已降级为普通通知，请查看诊断与权限' : ''}'
        '${snoozed
            ? '\n已延后，等待下一次定时触发'
            : result['stoppedAt'] != null
            ? started != null
                  ? '\n铃声已停止'
                  : result['reason'] == 'audio focus denied'
                  ? '\n未能播放：系统拒绝音频焦点，已停止本次尝试'
                  : '\n未开始播放，本次尝试已结束'
            : ''}'
        '${result['clockReason'] != null ? '\n${DesktopService.clockFailureText(result['clockReason'])}' : ''}'
        '${!screenOn && started == null && clockRequested == null && DateTime.now().millisecondsSinceEpoch > at + 10000 ? '\n尚未确认播放，请复制诊断排查' : ''}';
  }

  Future<void> action(Future<void> Function() work) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await work();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(safeError(e))));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget section(
    String title,
    IconData icon,
    List<Widget> children, {
    bool expanded = false,
  }) => Card(
    margin: const EdgeInsets.only(bottom: 12),
    elevation: 0,
    clipBehavior: Clip.antiAlias,
    color: colorsOf(context).panel,
    child: ExpansionTile(
      initiallyExpanded: expanded,
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: colorsOf(context).cyan.withValues(alpha: .10),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, size: 20, color: colorsOf(context).cyan),
      ),
      title: Text(
        title,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: children,
    ),
  );
  Widget text(String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Text(
        value,
        style: TextStyle(fontSize: 12, color: colorsOf(context).muted),
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: app,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: AppAmbient(
        child: SafeArea(
          top: false,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              section('数据库与同步', Icons.cloud_outlined, [
                text(app.sync.status),
                if (app.sync.config != null)
                  text(
                    '${app.sync.config!.host}:${app.sync.config!.port} / ${app.sync.config!.database}',
                  ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: busy
                          ? null
                          : () => action(() async {
                              final config = await connectionDialog(
                                context,
                                app.sync.config,
                              );
                              if (config != null) await app.configure(config);
                            }),
                      icon: const Icon(Icons.cable),
                      label: const Text('配置连接'),
                    ),
                    OutlinedButton(
                      onPressed: busy ? null : () => action(app.sync.sync),
                      child: const Text('立即同步'),
                    ),
                    if (app.sync.config != null)
                      TextButton(
                        onPressed: busy
                            ? null
                            : () => action(() => app.configure(null)),
                        child: const Text('切换离线'),
                      ),
                  ],
                ),
                text('连接电脑数据库时，请填写电脑的局域网或 VPN 地址。127.0.0.1 在手机上指向手机自己。'),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('后台补同步'),
                  subtitle: const Text('系统允许时运行；需要记住设备和连接信息'),
                  value: app.backgroundSync,
                  onChanged: busy
                      ? null
                      : (v) => action(() => app.setting('background_sync', v)),
                ),
                text(
                  '后台约每 15 分钟获得一次运行机会，也可能被系统延后。电脑刚新增的事项，需要手机成功同步后才会安排提醒。手动锁定会暂停后台同步。',
                ),
                if (app.store.getMeta('background_last_success') != null)
                  text(
                    '上次后台同步：${app.store.getMeta('background_last_success')}',
                  ),
                if (app.sync.envelopeConflict) ...[
                  text('两台设备更改了主密码，请选择保留哪一份密钥包。'),
                  Wrap(
                    spacing: 8,
                    children: [
                      OutlinedButton(
                        onPressed: () => action(
                          () =>
                              app.sync.resolveEnvelopeConflict(keepLocal: true),
                        ),
                        child: const Text('保留本机'),
                      ),
                      OutlinedButton(
                        onPressed: () => action(
                          () => app.sync.resolveEnvelopeConflict(
                            keepLocal: false,
                          ),
                        ),
                        child: const Text('采用服务器'),
                      ),
                    ],
                  ),
                ],
                if (app.sync.devices.isNotEmpty) ...[
                  const Divider(),
                  text('已登记设备'),
                  for (final device in app.sync.devices)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        '${device['device_id']}',
                        style: const TextStyle(fontSize: 12),
                      ),
                      subtitle: Text(
                        '游标 ${device['last_cursor'] ?? device['ack_cursor'] ?? '—'} · ${device['last_seen'] ?? ''}',
                      ),
                    ),
                ],
              ], expanded: true),
              section('系统提醒', Icons.notifications_outlined, [
                SystemClockTestPanel(desktop: app.desktop),
                const Divider(height: 32),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('备忘录到期提醒'),
                ),
                text(app.desktop.status),
                if (!app.notificationsEnabled) text('本机提醒已暂停，开启后才会登记事项闹铃。'),
                if (app.desktop.nextReminderAt != null)
                  text(
                    '下一次本机计划：${app.desktop.nextReminderAt!.toLocal().toString().substring(0, 16)}',
                  ),
                SwitchListTile.adaptive(
                  key: const Key('alarm-reminders'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('息屏时系统时钟响铃'),
                  subtitle: const Text('亮屏时使用顶部通知和一次提示音'),
                  value: app.alarmReminders,
                  onChanged: busy
                      ? null
                      : (v) => action(() => app.setting('alarm_reminders', v)),
                ),
                if (app.alarmReminders || app.hasForceAlarmMemos) ...[
                  text(
                    '到点时按手机屏幕状态选择：息屏交给系统时钟启动 1 秒倒计时；亮屏时，无论在星记、其他应用或已划走星记，都显示通知并播放一次提示音。单独开启「闹铃提醒」的事项亮屏也会调用系统时钟，且不参与夜间免打扰顺延。关闭提醒不会完成备忘录。',
                  ),
                  if (!app.desktop.clockBackgroundAllowed) ...[
                    text(
                      '后台调用需要 Android 的“显示在其他应用上层”授权。请在系统设置中找到星记并允许；星记不绘制悬浮窗。缺少授权时，后台只能保留普通提醒。',
                    ),
                    OutlinedButton.icon(
                      onPressed: () =>
                          action(app.desktop.clockBackgroundSettings),
                      icon: const Icon(Icons.alarm_on_outlined),
                      label: const Text('允许后台调用时钟'),
                    ),
                  ],
                  if (!app.desktop.clockAvailable)
                    text('尚未找到支持倒计时的时钟，请先确认手机时钟已启用，再试上方 10 秒测试。'),
                  OutlinedButton.icon(
                    onPressed: () =>
                        action(app.desktop.screenOnNotificationSettings),
                    icon: const Icon(Icons.notifications_outlined),
                    label: const Text('亮屏通知设置'),
                  ),
                  text('亮屏提醒使用通知音量。请允许“亮屏提醒”的声音和顶部横幅；静音、勿扰及系统通知设置仍然生效。'),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton(
                        onPressed: busy || !app.notificationsEnabled
                            ? null
                            : () => action(() async {
                                await app.desktop.scheduleTimedTest();
                                _watchTest();
                              }),
                        child: const Text('30 秒后事项测试'),
                      ),
                      TextButton(
                        onPressed: () => action(app.desktop.alarmSoundSettings),
                        child: const Text('调整闹钟音量'),
                      ),
                    ],
                  ),
                  text(
                    '此测试与真实事项使用相同的系统排程和后台时钟调用。点击后可切换其他应用或锁屏等待，不会新增备忘录。上方 10 秒测试只验证前台交接。',
                  ),
                  text('到点前改期、完成、删除或关闭本机提醒会撤销排程；已经交给时钟的那轮倒计时或铃声，请在时钟中关闭。'),
                  if (testStatus.isNotEmpty) ...[
                    text(testStatus),
                    TextButton(
                      onPressed: () => action(app.desktop.cancelTimedTest),
                      child: const Text('取消定时测试'),
                    ),
                  ],
                  if (app.desktop.clockReminder.isNotEmpty)
                    text(
                      '最近息屏时钟交接：${app.desktop.clockReminder['status'] == 'request_sent'
                          ? '请求已发送给系统时钟，实际响铃待确认'
                          : app.desktop.clockReminder['status'] == 'requesting'
                          ? '尚未确认请求是否发出，请复制诊断'
                          : DesktopService.clockFailureText(app.desktop.clockReminder['reason'])}',
                    ),
                ],
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('本机提醒'),
                  value: app.notificationsEnabled,
                  onChanged: busy
                      ? null
                      : (v) => action(() => app.setting('notifications', v)),
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('通知显示标题'),
                  subtitle: const Text('开启后标题会出现在通知和系统时钟中'),
                  value: app.showTitles,
                  onChanged: busy
                      ? null
                      : (v) => action(() => app.setting('show_titles', v)),
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('夜间静默'),
                  subtitle: const Text('22:00—08:00 的提醒顺延到 08:00'),
                  value: app.quiet,
                  onChanged: busy
                      ? null
                      : (v) => action(() => app.setting('quiet', v)),
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton(
                      onPressed: () => action(app.desktop.requestPermissions),
                      child: const Text('申请通知权限'),
                    ),
                    OutlinedButton(
                      onPressed: () =>
                          action(app.desktop.openNotificationSettings),
                      child: const Text('通知设置'),
                    ),
                    if (!app.desktop.exact)
                      OutlinedButton(
                        onPressed: () => action(app.desktop.exactSettings),
                        child: const Text('允许准时提醒'),
                      ),
                    OutlinedButton(
                      onPressed: () => action(app.desktop.test),
                      child: const Text('测试通知'),
                    ),
                    TextButton(
                      onPressed: () => action(() => app.schedule(force: true)),
                      child: const Text('重新排程'),
                    ),
                  ],
                ),
                text('已同步并登记的提醒可离线工作。手机关机、强行停止、关闭通知或厂商省电策略可能影响送达；重新打开会检查并补排。'),
                text('计划数来自星记保存的日期排程；到点才创建系统倒计时。“请求已发送”不代表已经响铃，实际声音以手机时钟为准。'),
                text(
                  '小米/红米/澎湃系统：还需在星记的应用设置中手动核对自启动、后台弹出界面和省电限制。厂商权限不能可靠读取，请授权后用 30 秒事项测试验证。',
                ),
                if (app.desktop.batteryOptimized)
                  text('系统仍对星记启用电池优化；长时间锁屏测试时请记录该设置。'),
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed: () => action(app.desktop.appSettings),
                      child: const Text('打开星记系统设置'),
                    ),
                    TextButton(
                      onPressed: () => action(app.desktop.refreshState),
                      child: const Text('刷新提醒状态'),
                    ),
                  ],
                ),
              ]),
              section('安全与备份', Icons.shield_outlined, [
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('三天内免输主密码'),
                  subtitle: const Text('使用设备密钥保护，每三天验证一次'),
                  value: app.remember,
                  onChanged: busy ? null : (v) => action(() => app.setTrust(v)),
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton(
                      onPressed: busy
                          ? null
                          : () => action(() async {
                              final value = await secretDialog(
                                context,
                                title: '更改主密码',
                                newPassword: true,
                                allowRecovery: false,
                              );
                              if (value != null) {
                                await app.changePassword(value.secret);
                              }
                            }),
                      child: const Text('更改主密码'),
                    ),
                    OutlinedButton(
                      onPressed: busy
                          ? null
                          : () => action(() => exportBackup(context, app)),
                      child: const Text('导出加密备份'),
                    ),
                    TextButton(
                      onPressed: busy
                          ? null
                          : () => action(() async {
                              await app.lock();
                              if (context.mounted) Navigator.pop(context);
                            }),
                      child: const Text('立即锁定'),
                    ),
                  ],
                ),
                text(
                  '备份可在手机或电脑的首次使用页面恢复。本机图片未纳入备份。请保存主密码或恢复码。更改主密码后重新导出备份；已有备份不会自动失效。',
                ),
                text('资料库 ID'),
                SelectableText(
                  app.crypto.vaultId ?? '',
                  style: const TextStyle(fontSize: 12),
                ),
                TextButton(
                  onPressed: () => Clipboard.setData(
                    ClipboardData(text: app.crypto.vaultId ?? ''),
                  ),
                  child: const Text('复制资料库 ID'),
                ),
              ]),
              section('外观与资料', Icons.info_outline, [
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('深色模式'),
                  value: app.darkMode,
                  onChanged: (_) => app.toggleTheme(),
                ),
                text('星记 ${appBuildName ?? '0.5.1'} · Android\n兼容 Android 8.0 及以上'),
                TextButton(
                  onPressed: () => showLicensePage(
                    context: context,
                    applicationName: '星记',
                    applicationVersion: appBuildName,
                  ),
                  child: const Text('开源组件许可'),
                ),
                text('本地资料目录'),
                SelectableText(
                  app.dataDirectory,
                  style: const TextStyle(fontSize: 12),
                ),
                text(
                  '备忘录内容加密保存在本机 SQLite，并与 PostgreSQL 同步。完成归档长期保留；永久删除需二次确认。系统运行元数据和提醒时间并非全部加密。',
                ),
              ]),
            ],
          ),
        ),
      ),
    ),
  );
}
