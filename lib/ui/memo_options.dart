import 'package:flutter/material.dart';

import '../core/models.dart';
import 'memo_actions.dart';
import 'theme.dart';

Future<Memo?> memoOptionsDialog(BuildContext context, Memo memo) =>
    showDialog<Memo>(
      context: context,
      builder: (_) => MemoOptionsDialog(memo: memo),
    );

class MemoOptionsDialog extends StatefulWidget {
  const MemoOptionsDialog({super.key, required this.memo});
  final Memo memo;
  @override
  State<MemoOptionsDialog> createState() => _MemoOptionsDialogState();
}

class _MemoOptionsDialogState extends State<MemoOptionsDialog> {
  late Memo draft;
  late final TextEditingController tags;
  final itemText = TextEditingController();
  String? error;

  @override
  void initState() {
    super.initState();
    draft = widget.memo;
    tags = TextEditingController(text: draft.tags.join('，'));
  }

  @override
  void dispose() {
    tags.dispose();
    itemText.dispose();
    super.dispose();
  }

  void edit(Json fields) => setState(() => draft = draft.edit(fields));
  void addItem() {
    final text = itemText.text.trim();
    if (text.isEmpty) return;
    if (draft.checklist.length >= 100) {
      setState(() => error = '清单最多 100 项');
      return;
    }
    edit({
      'checklist': [
        ...draft.checklist.map((i) => i.toJson()),
        CheckItem(text: text).toJson(),
      ],
    });
    itemText.clear();
  }

  void submit() {
    if (itemText.text.trim().isNotEmpty) addItem();
    final values = tags.text
        .split(RegExp('[,，]'))
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .toSet()
        .toList();
    if (values.length > 20 || itemText.text.trim().isNotEmpty) {
      setState(() => error = values.length > 20 ? '标签最多 20 个' : '清单最多 100 项');
      return;
    }
    Navigator.pop(context, draft.edit({'tags': values}));
  }

  @override
  Widget build(BuildContext context) {
    final c = colorsOf(context);
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 560,
          maxHeight: MediaQuery.sizeOf(context).height - 48,
        ),
        child: AnimatedSize(
          duration: const Duration(milliseconds: 160),
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '更多设置',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                Text('这些都是可选项，保持默认也可以保存。', style: TextStyle(color: c.muted)),
                const SizedBox(height: 20),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        TextField(
                          key: const Key('options-tags'),
                          controller: tags,
                          decoration: const InputDecoration(
                            labelText: '标签',
                            hintText: '例如：工作，生活',
                          ),
                        ),
                        const SizedBox(height: 16),
                        DropdownButtonFormField<int>(
                          initialValue: draft.priority,
                          decoration: const InputDecoration(labelText: '重要程度'),
                          items: [0, 1, 2, 3]
                              .map(
                                (v) => DropdownMenuItem(
                                  value: v,
                                  child: Text(priorityLabel(v)),
                                ),
                              )
                              .toList(),
                          onChanged: (v) => edit({'priority': v}),
                        ),
                        const SizedBox(height: 16),
                        DropdownButtonFormField<String>(
                          initialValue: draft.timezone,
                          isExpanded: true,
                          decoration: const InputDecoration(labelText: '时区'),
                          items:
                              {
                                    draft.timezone,
                                    'Asia/Shanghai',
                                    'UTC',
                                    'America/New_York',
                                    'Europe/London',
                                  }
                                  .map(
                                    (z) => DropdownMenuItem(
                                      value: z,
                                      child: Text(z),
                                    ),
                                  )
                                  .toList(),
                          onChanged: (v) => edit({'timezone': v}),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '日期和时间按所选时区显示。修改时区不会改变已设置的实际提醒时刻。',
                          style: TextStyle(fontSize: 12, color: c.muted),
                        ),
                        const SizedBox(height: 16),
                        DropdownButtonFormField<String>(
                          initialValue: draft.recurrence,
                          decoration: const InputDecoration(labelText: '重复'),
                          items: ['none', 'daily', 'weekdays', 'weekly']
                              .map(
                                (v) => DropdownMenuItem(
                                  value: v,
                                  child: Text(recurrenceLabel(v)),
                                ),
                              )
                              .toList(),
                          onChanged: draft.dueAt == null
                              ? null
                              : (v) => edit({'recurrence': v}),
                        ),
                        const SizedBox(height: 16),
                        const Text('提醒方式'),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          children: {0, 5, 30, 1440, ...draft.reminderOffsets}
                              .map(
                                (n) => FilterChip(
                                  label: Text(offsetLabel(n)),
                                  selected: draft.reminderOffsets.contains(n),
                                  onSelected: (selected) {
                                    final offsets = draft.reminderOffsets
                                        .toSet();
                                    selected
                                        ? offsets.add(n)
                                        : offsets.remove(n);
                                    if (offsets.isEmpty) offsets.add(0);
                                    edit({
                                      'reminder_offsets': offsets.toList()
                                        ..sort(),
                                    });
                                  },
                                ),
                              )
                              .toList(),
                        ),
                        const SizedBox(height: 16),
                        const Text('清单'),
                        ...draft.checklist.asMap().entries.map(
                          (entry) => Row(
                            children: [
                              Checkbox(
                                value: entry.value.done,
                                onChanged: (done) {
                                  final items = draft.checklist.toList();
                                  items[entry.key] = entry.value.copyWith(
                                    done: done,
                                  );
                                  edit({
                                    'checklist': items
                                        .map((i) => i.toJson())
                                        .toList(),
                                  });
                                },
                              ),
                              Expanded(child: Text(entry.value.text)),
                              IconButton(
                                tooltip: '移除此清单项',
                                icon: const Icon(Icons.close, size: 18),
                                onPressed: () {
                                  final items = draft.checklist.toList()
                                    ..removeAt(entry.key);
                                  edit({
                                    'checklist': items
                                        .map((i) => i.toJson())
                                        .toList(),
                                  });
                                },
                              ),
                            ],
                          ),
                        ),
                        TextField(
                          controller: itemText,
                          onSubmitted: (_) => addItem(),
                          decoration: InputDecoration(
                            hintText: '添加清单项',
                            suffixIcon: IconButton(
                              tooltip: '添加清单项',
                              onPressed: addItem,
                              icon: const Icon(Icons.add),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (error != null)
                  Text(error!, style: TextStyle(color: c.danger)),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: 10),
                    FilledButton(onPressed: submit, child: const Text('应用设置')),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
