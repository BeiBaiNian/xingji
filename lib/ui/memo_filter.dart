import 'package:flutter/material.dart';

import 'theme.dart';

const memoFilters = {
  'all': '全部备忘录',
  'today': '今天',
  'upcoming': '以后',
  'completed': '已完成',
  'date': '按日期查看',
  'overdue': '逾期',
  'unscheduled': '未设提醒',
  'trash': '回收站',
  'conflicts': '冲突副本',
};

const _icons = {
  'all': Icons.notes_rounded,
  'today': Icons.today_outlined,
  'upcoming': Icons.event_outlined,
  'completed': Icons.task_alt_rounded,
  'date': Icons.calendar_month_outlined,
  'overdue': Icons.history_rounded,
  'unscheduled': Icons.notifications_none_rounded,
  'trash': Icons.delete_outline_rounded,
  'conflicts': Icons.file_copy_outlined,
};

class MemoFilterButton extends StatelessWidget {
  const MemoFilterButton({
    super.key,
    required this.value,
    required this.onChanged,
  });
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = colorsOf(context);
    return PopupMenuButton<String>(
      key: const Key('memo-filter'),
      tooltip: '选择备忘录范围',
      position: PopupMenuPosition.under,
      offset: const Offset(0, 6),
      constraints: const BoxConstraints(minWidth: 248, maxWidth: 248),
      padding: EdgeInsets.zero,
      menuPadding: const EdgeInsets.symmetric(vertical: 8),
      borderRadius: BorderRadius.circular(14),
      elevation: 8,
      color: c.panel,
      surfaceTintColor: Colors.transparent,
      shadowColor: const Color(0xFF475569).withValues(alpha: .18),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: c.line),
      ),
      onSelected: onChanged,
      itemBuilder: (_) => [
        for (final entry in memoFilters.entries) ...[
          if (entry.key == 'overdue') const PopupMenuDivider(height: 16),
          PopupMenuItem<String>(
            key: ValueKey('filter-option-${entry.key}'),
            value: entry.key,
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Semantics(
              selected: value == entry.key,
              child: Container(
                height: 40,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: value == entry.key
                      ? c.cyan.withValues(alpha: .1)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Icon(
                      _icons[entry.key],
                      size: 18,
                      color: value == entry.key ? c.cyan : c.muted,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        entry.value,
                        style: TextStyle(
                          fontSize: 14,
                          color: value == entry.key ? c.cyan : null,
                          fontWeight: value == entry.key
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ),
                    if (value == entry.key)
                      Icon(Icons.check_rounded, size: 18, color: c.cyan),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
      child: Ink(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: c.panel.withValues(alpha: .88),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: c.line.withValues(alpha: .82)),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF64748B).withValues(alpha: .06),
              blurRadius: 12,
              offset: const Offset(0, 4),
              spreadRadius: -6,
            ),
          ],
        ),
        child: Row(
          children: [
            Icon(_icons[value], size: 18, color: c.cyan),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                memoFilters[value] ?? '全部备忘录',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Icon(Icons.keyboard_arrow_down_rounded, size: 20, color: c.muted),
          ],
        ),
      ),
    );
  }
}
