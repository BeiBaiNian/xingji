import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../platform/desktop_service.dart';

/// The OS clock has no playback callback. Only the user's observation is a result.
class SystemClockTestPanel extends StatefulWidget {
  const SystemClockTestPanel({super.key, required this.desktop});
  final DesktopService desktop;

  @override
  State<SystemClockTestPanel> createState() => _SystemClockTestPanelState();
}

class _SystemClockTestPanelState extends State<SystemClockTestPanel> {
  static const scenarios = {
    'screen_on': '亮屏留在星记',
    'screen_off': '息屏锁屏',
    'other_app': '切换其他应用',
    'swiped_away': '划走星记',
  };
  static const outcomes = {
    'rang': '响铃正常',
    'notification_only': '只有提示音',
    'silent': '没有响铃',
    'not_completed': '未完成测试',
  };
  String scenario = 'screen_on';
  bool busy = false;
  Timer? cooldown;
  Map<String, dynamic> get receipt => widget.desktop.systemClockTest;
  int get remainingMillis {
    if (receipt['status'] != 'request_sent') return 0;
    final age =
        DateTime.now().millisecondsSinceEpoch -
        (receipt['requestedAt'] as int? ?? 0);
    return age >= 0 && age < 10000 ? 10000 - age : 0;
  }

  @override
  void initState() {
    super.initState();
    scenario = receipt['scenario'] as String? ?? scenario;
    watchCooldown();
  }

  @override
  void didUpdateWidget(covariant SystemClockTestPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    watchCooldown();
  }

  void watchCooldown() {
    cooldown?.cancel();
    if (remainingMillis > 0) {
      cooldown = Timer(Duration(milliseconds: remainingMillis + 50), () {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    cooldown?.cancel();
    super.dispose();
  }

  Future<void> action(Future<void> Function() work) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await work();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('操作未完成，请重试；可复制诊断排查')));
      }
    } finally {
      if (mounted) {
        watchCooldown();
        setState(() => busy = false);
      }
    }
  }

  String get status => switch (receipt['status']) {
    'request_sent' => '已发出 10 秒倒计时请求，实际响铃待你确认。',
    'clock_handler_missing' => '没有找到支持倒计时的时钟应用，请确认手机时钟已启用。',
    'clock_permission_denied' => '系统拒绝了时钟调用，请复制诊断排查。',
    'clock_foreground_required' => '请回到星记设置页面，再点击测试。',
    'clock_launch_failed' => '时钟调用失败，请复制诊断排查。',
    'requesting' => '上次调用中断，尚未确认请求是否发出；请先查看手机时钟。',
    _ => '',
  };

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('系统时钟测试', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 8),
      const Text('点击后立即交给手机时钟倒计时 10 秒。若出现时钟或选择页面，请先完成确认，再切换到所选状态。'),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        children: [
          for (final entry in scenarios.entries)
            ChoiceChip(
              key: ValueKey('clock-scenario-${entry.key}'),
              label: Text(entry.value),
              selected: scenario == entry.key,
              onSelected: busy || remainingMillis > 0
                  ? null
                  : (_) => setState(() => scenario = entry.key),
            ),
        ],
      ),
      const SizedBox(height: 8),
      FilledButton.icon(
        key: const Key('system-clock-test'),
        onPressed: busy || remainingMillis > 0
            ? null
            : () => action(() => widget.desktop.testSystemClock(scenario)),
        icon: const Icon(Icons.timer_outlined),
        label: const Text('系统时钟 10 秒测试'),
      ),
      if (remainingMillis > 0) const Text('请等待本轮 10 秒测试结束，再开始下一轮。'),
      const SizedBox(height: 8),
      const Text(
        '声音和锁屏画面由时钟应用负责，请在时钟中关闭本轮倒计时后再重试。此测试不改动事项提醒。',
        style: TextStyle(fontSize: 12),
      ),
      if (status.isNotEmpty) ...[
        const SizedBox(height: 12),
        Text(status, key: const Key('clock-test-status')),
        if (receipt['requestedAt'] case final int at)
          Text(
            '最近一轮：${DateTime.fromMillisecondsSinceEpoch(at).toLocal().toString().substring(0, 19)} · '
            '${scenarios[receipt['scenario']] ?? '未记录场景'}',
            style: const TextStyle(fontSize: 12),
          ),
        if (receipt['status'] == 'request_sent') ...[
          const SizedBox(height: 8),
          const Text('测试后记录你实际听到的结果：'),
          Wrap(
            spacing: 8,
            children: [
              for (final entry in outcomes.entries)
                ChoiceChip(
                  key: ValueKey('clock-result-${entry.key}'),
                  label: Text(entry.value),
                  selected: receipt['userResult'] == entry.key,
                  onSelected: busy
                      ? null
                      : (_) => action(
                          () => widget.desktop.reportSystemClockTest(
                            receipt['id'] as String,
                            entry.key,
                          ),
                        ),
                ),
            ],
          ),
          if (outcomes[receipt['userResult']] case final String outcome)
            Text('你的反馈：$outcome（手动记录）'),
        ],
      ],
      const SizedBox(height: 8),
      OutlinedButton.icon(
        key: const Key('copy-reminder-diagnostics'),
        onPressed: busy
            ? null
            : () => action(() async {
                final report = await widget.desktop.reminderDiagnostics();
                if (report.isEmpty) throw StateError('empty diagnostics');
                await Clipboard.setData(ClipboardData(text: report));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('已复制最近 10 条事件及测试摘要，不含事项标题正文')),
                  );
                }
              }),
        icon: const Icon(Icons.copy_outlined),
        label: const Text('复制最近 10 条诊断'),
      ),
    ],
  );
}
