import 'package:flutter/material.dart';

import '../core/app_controller.dart';
import '../core/models.dart';
import 'theme.dart';

Future<bool> confirmDeleteMemo(BuildContext context, Memo memo) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这条备忘录？'),
        content: SizedBox(
          width: 380,
          child: Text('“${memo.title}”将移入回收站，并取消对应提醒。\n之后仍可从回收站恢复。'),
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: colorsOf(context).danger,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认删除'),
          ),
        ],
      ),
    ) ??
    false;

Future<bool> deleteMemoWithConfirmation(
  BuildContext context,
  AppController app,
  Memo memo,
) async {
  if (!await confirmDeleteMemo(context, memo)) return false;
  final current = app.memos.where((m) => m.id == memo.id).firstOrNull;
  if (current == null || current.deleted) return false;
  await app.delete(current);
  app.select(null);
  return true;
}

Future<bool> purgeMemoWithConfirmation(
  BuildContext context,
  AppController app,
  Memo memo,
) async {
  final confirmed =
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('永久删除这条备忘录？'),
          content: SizedBox(
            width: 420,
            child: Text(
              '“${memo.title}”的本机内容与历史将移除，联网后同步清理 PostgreSQL 和其他设备的副本。\n\n此操作无法从回收站恢复。已有导出备份不受影响。',
            ),
          ),
          actions: [
            TextButton(
              autofocus: true,
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const Key('confirm-purge'),
              style: FilledButton.styleFrom(
                backgroundColor: colorsOf(context).danger,
              ),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认永久删除'),
            ),
          ],
        ),
      ) ??
      false;
  if (!confirmed) return false;
  await app.purge(memo);
  return true;
}

String priorityLabel(int value) => switch (value) {
  0 => '较低',
  2 => '重要',
  3 => '紧急',
  _ => '普通',
};

String recurrenceLabel(String value) => switch (value) {
  'daily' => '每天',
  'weekly' => '每周',
  'weekdays' => '工作日',
  _ => '不重复',
};

String offsetLabel(int minutes) => minutes == 0
    ? '准时'
    : minutes >= 1440 && minutes % 1440 == 0
    ? '提前 ${minutes ~/ 1440} 天'
    : '提前 $minutes 分钟';
