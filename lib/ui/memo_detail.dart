import 'package:flutter/material.dart';
import 'package:timezone/timezone.dart' as tz;

import '../core/app_controller.dart';
import '../core/models.dart';
import 'dialogs.dart';
import 'memo_actions.dart';
import 'memo_images.dart';
import 'theme.dart';

Color archiveColor(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? const Color(0xFFB9C0C7)
    : const Color(0xFF646B73);

String reminderInZone(Memo memo) {
  if (memo.reminderAt == null) return '未设置提醒';
  final t = tz.TZDateTime.from(memo.reminderAt!, tz.getLocation(memo.timezone));
  return '${t.year}/${t.month.toString().padLeft(2, '0')}/${t.day.toString().padLeft(2, '0')} '
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

class MemoDetail extends StatelessWidget {
  const MemoDetail({
    super.key,
    required this.app,
    required this.memo,
    required this.onEdit,
    required this.onToggle,
    required this.onDelete,
    required this.onRestore,
    required this.onStopRepeat,
    required this.onPurge,
    this.onBackToDates,
  });
  final AppController app;
  final Memo memo;
  final VoidCallback onEdit,
      onToggle,
      onDelete,
      onRestore,
      onStopRepeat,
      onPurge;
  final VoidCallback? onBackToDates;

  @override
  Widget build(BuildContext context) {
    final c = colorsOf(context);
    final archived = archiveColor(context);
    final textColor = memo.done
        ? archived
        : Theme.of(context).colorScheme.onSurface;
    Widget property(String label, String value) => SizedBox(
      width: 280,
      child: Padding(
        padding: const EdgeInsets.only(right: 18, bottom: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: TextStyle(fontSize: 12, color: c.muted)),
            const SizedBox(height: 5),
            SelectableText(
              value,
              style: TextStyle(color: textColor, fontSize: 14),
            ),
          ],
        ),
      ),
    );
    return ColoredBox(
      color: c.panel,
      child: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(30, 24, 30, 28),
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 900),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (onBackToDates != null) ...[
                        TextButton.icon(
                          key: const Key('back-to-dates'),
                          onPressed: onBackToDates,
                          icon: const Icon(Icons.arrow_back, size: 18),
                          label: const Text('返回日期查看'),
                        ),
                        const SizedBox(height: 12),
                      ],
                      Row(
                        children: [
                          Icon(
                            memo.deleted
                                ? Icons.delete_outline
                                : memo.done
                                ? Icons.inventory_2_outlined
                                : Icons.description_outlined,
                            color: memo.done ? archived : c.cyan,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              memo.deleted
                                  ? '回收站'
                                  : memo.done
                                  ? '已完成 · 已归档'
                                  : '备忘录详情',
                              style: TextStyle(
                                color: memo.done ? archived : c.muted,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: '修改历史',
                            icon: const Icon(Icons.history, size: 20),
                            onPressed: () => showHistory(context, app, memo),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      SelectableText(
                        memo.title,
                        key: const Key('detail-title'),
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -.4,
                          color: textColor,
                        ),
                      ),
                      const SizedBox(height: 20),
                      SelectableText(
                        memo.body.isEmpty ? '未填写正文' : memo.body,
                        key: const Key('detail-body'),
                        style: TextStyle(
                          fontSize: 16,
                          height: 1.8,
                          color: textColor,
                        ),
                      ),
                      MemoImages(app: app, memoId: memo.id),
                      const SizedBox(height: 28),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: memo.done
                              ? archived.withValues(alpha: .08)
                              : c.cyan.withValues(alpha: .07),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: c.line.withValues(alpha: .72),
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              memo.done
                                  ? Icons.check_circle_outline
                                  : Icons.notifications_active_outlined,
                              color: memo.done ? archived : c.cyan,
                              size: 28,
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    memo.done
                                        ? '原提醒时间 · 已完成，不再提醒'
                                        : memo.snoozedUntil != null
                                        ? '稍后提醒时间'
                                        : '提醒时间',
                                    style: TextStyle(
                                      color: c.muted,
                                      fontSize: 12,
                                    ),
                                  ),
                                  const SizedBox(height: 5),
                                  Text(
                                    reminderInZone(memo),
                                    style: TextStyle(
                                      fontSize: 23,
                                      fontWeight: FontWeight.w600,
                                      color: textColor,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 26),
                      Wrap(
                        children: [
                          property('时区', memo.timezone),
                          property('重要程度', priorityLabel(memo.priority)),
                          property('重复', recurrenceLabel(memo.recurrence)),
                          property(
                            '提醒方式',
                            memo.reminderOffsets.map(offsetLabel).join('、'),
                          ),
                          if (memo.done)
                            property(
                              '完成时间',
                              dateLabel(memo.completedAt, full: true),
                            ),
                        ],
                      ),
                      Text(
                        '标签',
                        style: TextStyle(color: c.muted, fontSize: 12),
                      ),
                      const SizedBox(height: 8),
                      if (memo.tags.isEmpty)
                        Text('未设置标签', style: TextStyle(color: textColor))
                      else
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: memo.tags
                              .map((t) => Chip(label: Text(t)))
                              .toList(),
                        ),
                      if (memo.checklist.isNotEmpty) ...[
                        const SizedBox(height: 24),
                        Text(
                          '清单',
                          style: TextStyle(color: c.muted, fontSize: 12),
                        ),
                        ...memo.checklist.map(
                          (item) => Padding(
                            padding: const EdgeInsets.symmetric(vertical: 7),
                            child: Row(
                              children: [
                                Icon(
                                  item.done
                                      ? Icons.check_box_outlined
                                      : Icons.check_box_outline_blank,
                                  size: 20,
                                  color: item.done || memo.done
                                      ? archived
                                      : c.cyan,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    item.text,
                                    style: TextStyle(
                                      color: textColor,
                                      decoration: item.done
                                          ? TextDecoration.lineThrough
                                          : null,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                      if (memo.conflictOf != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 20),
                          child: Text(
                            '这是一份冲突副本，原备忘录也已保留。',
                            style: TextStyle(color: c.violet),
                          ),
                        ),
                      if (memo.done)
                        Padding(
                          padding: const EdgeInsets.only(top: 24),
                          child: Text(
                            '此备忘录已归档，内容完整保留。需要继续处理时可重新打开。',
                            style: TextStyle(color: archived),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const Divider(),
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: MediaQuery.sizeOf(context).width < 600 ? 16 : 30,
              vertical: 12,
            ),
            child: OverflowBar(
              spacing: 8,
              overflowSpacing: 8,
              alignment: MainAxisAlignment.end,
              children: [
                if (memo.deleted)
                  TextButton.icon(
                    key: const Key('purge-memo'),
                    onPressed: onPurge,
                    icon: const Icon(Icons.delete_forever_outlined, size: 19),
                    label: const Text('永久删除'),
                    style: TextButton.styleFrom(foregroundColor: c.danger),
                  ),
                if (!memo.deleted)
                  TextButton.icon(
                    onPressed: onDelete,
                    icon: const Icon(Icons.delete_outline, size: 19),
                    label: const Text('删除'),
                    style: TextButton.styleFrom(foregroundColor: c.danger),
                  ),
                if (memo.deleted)
                  FilledButton.icon(
                    onPressed: onRestore,
                    icon: const Icon(
                      Icons.restore_from_trash_outlined,
                      size: 19,
                    ),
                    label: const Text('恢复备忘录'),
                  )
                else ...[
                  if (memo.recurrence != 'none' && !memo.done)
                    PopupMenuButton<String>(
                      tooltip: '重复任务选项',
                      onSelected: (_) => onStopRepeat(),
                      itemBuilder: (_) => [
                        const PopupMenuItem(
                          value: 'stop',
                          child: Text('结束重复并归档'),
                        ),
                      ],
                    ),
                  if (!memo.done) ...[
                    OutlinedButton.icon(
                      key: const Key('edit-memo'),
                      onPressed: onEdit,
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      label: const Text('编辑'),
                    ),
                    const SizedBox(width: 12),
                  ],
                  FilledButton.icon(
                    onPressed: onToggle,
                    icon: Icon(memo.done ? Icons.undo : Icons.check, size: 18),
                    label: Text(
                      memo.done
                          ? '重新打开'
                          : memo.recurrence == 'none'
                          ? '完成并归档'
                          : '完成本次',
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
