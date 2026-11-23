// Explicit QA entrypoint. Never used by the release build or packaged installer.
import 'dart:convert';
import 'dart:io';

import 'package:xingji/core/models.dart';
import 'package:xingji/main.dart' as production;
import 'package:xingji/platform/desktop_service.dart';

Future<void> main(List<String> arguments) async {
  const profile = String.fromEnvironment('XINGJI_QA_PROFILE');
  const nativeOnly = bool.fromEnvironment('XINGJI_QA_NATIVE_ONLY');
  if (profile.isEmpty) {
    throw StateError('An explicit isolated QA profile is required');
  }
  final app = await production.launchXingJi([
    ...arguments,
    '--data-dir=$profile',
  ]);
  if (app == null) return;
  final report = File('$profile/native-report.json');
  if (!app.exists) {
    await app.create('Synthetic-QA-only-passphrase-2026', trust: true);
    app.recoveryCode = null;
  }
  if (!app.unlocked) return;
  if (!report.existsSync()) {
    final results = <String, dynamic>{
      'native_initialized': app.desktop.ready,
      'notifications_allowed': app.desktop.allowed,
      'hotkey_registered': app.desktop.hotkey,
      'initial_status': app.desktop.status,
    };
    try {
      if (!app.desktop.ready) {
        // Preserve the native HRESULT/stage in the report, rather than only
        // the user-facing status produced by DesktopService.initialize.
        await DesktopService.channel.invokeMethod('initialize');
        throw StateError(app.desktop.status);
      }
      final memo = Memo(
        title: '仅供系统提醒验证',
        dueAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
      );
      await app.save(memo);
      await app.schedule(force: true);
      final before = (await DesktopService.channel
          .invokeMapMethod<String, dynamic>('notificationState'))!;
      results['schedule_registered'] = before['scheduled'] == 1;
      final edited = memo.edit({
        'due_at_utc': DateTime.now()
            .toUtc()
            .add(const Duration(minutes: 7))
            .toIso8601String(),
      });
      await app.save(edited);
      await app.schedule(force: true);
      final after = (await DesktopService.channel
          .invokeMapMethod<String, dynamic>('notificationState'))!;
      results['old_schedule_replaced'] =
          after['scheduled'] == 1 &&
          (before['ids'] as List).single != (after['ids'] as List).single;
      await app.toggleDone(edited);
      await app.schedule(force: true);
      final completed = (await DesktopService.channel
          .invokeMapMethod<String, dynamic>('notificationState'))!;
      results['completion_cancels_schedule'] = completed['scheduled'] == 0;
      await app.delete(app.memos.firstWhere((m) => m.id == memo.id));
      await app.schedule(force: true);
      // Schedule directly to check delivery while this process is fully stopped.
      final at = DateTime.now().add(const Duration(seconds: 20));
      await DesktopService.channel.invokeMethod('replaceSchedules', {
        'items': [
          {
            'id': 'qaexit',
            'at': at.millisecondsSinceEpoch,
            'xml': DesktopService.toastXml(
              title: '星记 · 退出后提醒测试',
              body: '这是一条开发验证通知，应用已退出。',
            ),
          },
        ],
        'removeIds': <String>[],
      });
      results['delivery_due_at'] = at.toIso8601String();
      await report.writeAsString(
        const JsonEncoder.withIndent('  ').convert(results),
        flush: true,
      );
      await app.desktop.exit();
      return;
    } catch (e) {
      results['native_error_type'] = e.runtimeType.toString();
      results['native_error'] = e.toString();
      await report.writeAsString(
        const JsonEncoder.withIndent('  ').convert(results),
        flush: true,
      );
    }
  } else {
    final results = jsonDecode(await report.readAsString()) as Json;
    final state = (await DesktopService.channel
        .invokeMapMethod<String, dynamic>('notificationState'))!;
    results['delivered_while_app_stopped'] = (state['delivered'] as List)
        .contains('qaexit');
    results['relaunch_state'] = state;
    await report.writeAsString(
      const JsonEncoder.withIndent('  ').convert(results),
      flush: true,
    );
  }
  if (nativeOnly) {
    await app.desktop.exit();
    return;
  }
  if (app.memos.where((m) => !m.deleted).isEmpty) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day, 18).toUtc();
    final fixtures = [
      Memo(
        title: '整理本周的项目想法',
        body: '把零散的想法整理为可以执行的下一步。\n\n先确认最重要的一件事，再补充细节。',
        tags: ['工作', '灵感'],
        priority: 2,
        pinned: true,
        dueAt: today,
        checklist: [
          CheckItem(text: '回顾本周的笔记', done: true),
          CheckItem(text: '整理三个值得尝试的方向'),
          CheckItem(text: '写下下一步行动'),
        ],
      ),
      Memo(
        title: '给阅读留半小时',
        body: '放下屏幕，继续昨天没读完的章节。',
        tags: ['生活'],
        dueAt: today.add(const Duration(hours: 2)),
        recurrence: 'daily',
      ),
      Memo(
        title: '检查本地加密备份',
        body: '确认备份可读取，并妥善保管恢复资料。',
        tags: ['工作'],
        dueAt: today.subtract(const Duration(minutes: 30)),
      ),
      Memo(title: '周末去公园散步', body: '找一段安静的路，带上相机。', tags: ['生活', '灵感']),
      Memo(
        title: '整理下个月的学习清单',
        tags: ['学习'],
        dueAt: today.add(const Duration(days: 1)),
      ),
      Memo(
        title: '完成本周的桌面整理',
        tags: ['生活'],
        status: 'done',
        completedAt: now.toUtc(),
      ),
    ];
    for (final memo in fixtures) {
      await app.save(memo);
    }
    app.select(fixtures.first.id);
  }
  app.navigate('today');
}
