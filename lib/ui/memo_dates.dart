import 'package:flutter/material.dart';

import '../core/app_controller.dart';
import '../core/dated_memos.dart';
import 'memo_actions.dart';
import 'memo_detail.dart';
import 'theme.dart';

class MemoDates extends StatelessWidget {
  const MemoDates({super.key, required this.app, required this.onSelect});
  final AppController app;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final c = colorsOf(context);
    final day = app.browseDate;
    final rows = app.visible;
    final caption = switch (app.dateBasis) {
      'scheduled' => '按提醒日期查看当天安排，包括已经完成的记录。',
      'completed' => '按实际完成日期回看归档，未设提醒的完成事项也会显示。',
      _ => '未完成按提醒日期，已完成按实际完成日期。',
    };
    Future<void> pickDate() async {
      final value = await showDatePicker(
        context: context,
        initialDate: day,
        firstDate: DateTime(1900),
        lastDate: DateTime(2200, 12, 31),
        helpText: '查看哪一天的备忘录',
      );
      if (value != null) app.changeDateView(day: value);
    }

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 960),
        child: ListView.builder(
          key: const Key('date-browser'),
          padding: EdgeInsets.all(
            MediaQuery.sizeOf(context).width < 600 ? 16 : 28,
          ),
          itemCount: rows.length + 1,
          itemBuilder: (context, index) {
            if (index == 0) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '按日期查看',
                    style: TextStyle(fontSize: 26, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '回看完成记录，也可以查看当天安排与未来事项。',
                    style: TextStyle(color: c.muted),
                  ),
                  const SizedBox(height: 20),
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      IconButton(
                        key: const Key('date-previous'),
                        tooltip: '前一天',
                        onPressed: day.isAfter(DateTime(1900))
                            ? () => app.changeDateView(
                                day: DateTime(day.year, day.month, day.day - 1),
                              )
                            : null,
                        icon: const Icon(Icons.chevron_left),
                      ),
                      OutlinedButton.icon(
                        key: const Key('date-picker'),
                        onPressed: pickDate,
                        icon: const Icon(
                          Icons.calendar_month_outlined,
                          size: 20,
                        ),
                        label: Text('${day.year}年${day.month}月${day.day}日'),
                      ),
                      IconButton(
                        key: const Key('date-next'),
                        tooltip: '后一天',
                        onPressed: day.isBefore(DateTime(2200, 12, 31))
                            ? () => app.changeDateView(
                                day: DateTime(day.year, day.month, day.day + 1),
                              )
                            : null,
                        icon: const Icon(Icons.chevron_right),
                      ),
                      TextButton(
                        onPressed: () =>
                            app.changeDateView(day: DateTime.now()),
                        child: const Text('回到今天'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final entry in const {
                        'activity': '当天事项',
                        'scheduled': '安排日期',
                        'completed': '完成日期',
                      }.entries)
                        ChoiceChip(
                          key: ValueKey('date-basis-${entry.key}'),
                          label: Text(entry.value),
                          selected: app.dateBasis == entry.key,
                          onSelected: (_) => app.changeDateView(
                            basis: entry.key,
                            status: entry.key == 'completed' ? 'done' : 'all',
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(caption, style: TextStyle(color: c.muted, fontSize: 12)),
                  if (app.dateBasis != 'completed') ...[
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final entry in const {
                          'all': '全部',
                          'open': '未完成',
                          'done': '已完成',
                        }.entries)
                          FilterChip(
                            key: ValueKey('date-status-${entry.key}'),
                            label: Text(entry.value),
                            selected: app.dateStatus == entry.key,
                            onSelected: (_) =>
                                app.changeDateView(status: entry.key),
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 22),
                  Text(
                    '${rows.length} 项备忘录',
                    style: TextStyle(color: c.muted, fontSize: 12),
                  ),
                  const SizedBox(height: 12),
                  if (rows.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 32),
                      child: Text(
                        app.search.isEmpty ? '这一天没有符合条件的备忘录' : '这一天没有匹配搜索的备忘录',
                        style: TextStyle(color: c.muted),
                      ),
                    ),
                ],
              );
            }
            final memo = rows[index - 1];
            final color = memo.done ? archiveColor(context) : c.cyan;
            final time = memoDate(memo, app.dateBasis)!;
            final label =
                app.dateBasis == 'scheduled' ||
                    app.dateBasis == 'activity' && !memo.done
                ? '安排'
                : '完成';
            return Card(
              margin: const EdgeInsets.only(bottom: 10),
              elevation: 0,
              color: memo.done ? color.withValues(alpha: .06) : c.panel,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: BorderSide(color: c.line.withValues(alpha: .72)),
              ),
              child: ListTile(
                key: ValueKey('dated-row-${memo.id}'),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 10,
                ),
                leading: Icon(
                  memo.done ? Icons.task_alt : Icons.schedule,
                  color: color,
                ),
                title: Text(
                  memo.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: memo.done ? color : null,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: Text(
                  '$label ${dateLabel(time, full: true)}\n${memo.done ? '已完成 · 已归档' : '未完成'} · ${priorityLabel(memo.priority)}',
                  style: TextStyle(
                    fontSize: 12,
                    color: memo.done ? color : c.muted,
                  ),
                ),
                trailing: Icon(Icons.chevron_right, color: color),
                onTap: () => onSelect(memo.id),
              ),
            );
          },
        ),
      ),
    );
  }
}
