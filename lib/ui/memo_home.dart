import 'dart:async';

import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/today_agenda.dart';
import 'memo_actions.dart';
import 'memo_detail.dart';
import 'theme.dart';

class MemoHome extends StatefulWidget {
  const MemoHome({
    super.key,
    required this.memos,
    required this.notice,
    required this.onNew,
    required this.onSelect,
    required this.onFilter,
    this.clock = DateTime.now,
    this.compact = false,
  });
  final List<Memo> memos;
  final String? notice;
  final VoidCallback onNew;
  final ValueChanged<String> onSelect, onFilter;
  final DateTime Function() clock;
  final bool compact;

  @override
  State<MemoHome> createState() => _MemoHomeState();
}

class _MemoHomeState extends State<MemoHome> with WidgetsBindingObserver {
  Timer? _boundaryTimer;
  late TodayAgenda _agenda;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void didUpdateWidget(covariant MemoHome oldWidget) {
    super.didUpdateWidget(oldWidget);
    _refresh();
  }

  void _refresh() {
    _boundaryTimer?.cancel();
    final now = widget.clock();
    _agenda = TodayAgenda(widget.memos, now);
    // Rebuild only when the next deadline or calendar day changes. The timer
    // lives with this page, so editors and detail pages do not wake it up.
    if (_agenda.hasOpenMemos) {
      _boundaryTimer = Timer(_agenda.nextChange.difference(now), () {
        if (mounted) setState(_refresh);
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) setState(_refresh);
  }

  @override
  void dispose() {
    _boundaryTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Widget _filters() {
    final c = colorsOf(context);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final entry in const {
          'today': '今天',
          'upcoming': '以后',
          'completed': '已完成',
          'date': '按日期查看',
        }.entries)
          TextButton(
            onPressed: () => widget.onFilter(entry.key),
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 42),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              backgroundColor: c.panel.withValues(alpha: .72),
            ),
            child: Text(entry.value),
          ),
      ],
    );
  }

  Widget _newButton() => Pressable(
    child: FilledButton.icon(
      onPressed: widget.onNew,
      icon: const Icon(Icons.add, size: 20),
      label: const Text('新建备忘录'),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final c = colorsOf(context);
    final title = Text(
      widget.notice ??
          (widget.compact && _agenda.hasOpenMemos ? '今天待办' : '安排下一件事'),
      key: const Key('default-page-title'),
      style: TextStyle(
        fontSize: widget.compact && _agenda.hasOpenMemos ? 20 : 28,
        fontWeight: FontWeight.w600,
      ),
    );
    final iconSize = _agenda.hasOpenMemos ? 38.0 : 52.0;
    final icon = Container(
      width: iconSize + 20,
      height: iconSize + 20,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            c.cyan.withValues(alpha: .16),
            c.violet.withValues(alpha: .07),
          ],
        ),
        border: Border.all(color: c.panel.withValues(alpha: .82)),
      ),
      child: Icon(
        widget.notice == null
            ? Icons.edit_note_rounded
            : Icons.check_circle_outline,
        size: iconSize,
        color: c.cyan,
      ),
    );
    final description = widget.compact
        ? '查看今天的待办，或记下新的安排。'
        : '从左侧选择备忘录查看详情，或记下新的安排。';
    if (!_agenda.hasOpenMemos) {
      return Center(
        key: const Key('home-empty'),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(36),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 530),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                icon,
                const SizedBox(height: 18),
                title,
                const SizedBox(height: 12),
                Text(
                  description,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: c.muted),
                ),
                const SizedBox(height: 26),
                _newButton(),
                const SizedBox(height: 18),
                _filters(),
              ],
            ),
          ),
        ),
      );
    }
    final entries = <Widget>[
      if (widget.compact)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            children: [
              Expanded(child: title),
              const SizedBox(width: 8),
              _newButton(),
            ],
          ),
        ),
      if (!widget.compact)
        Padding(
          padding: const EdgeInsets.only(bottom: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 18,
                runSpacing: 14,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [icon, const SizedBox(width: 12), title],
                  ),
                  _newButton(),
                ],
              ),
              const SizedBox(height: 12),
              Text(description, style: TextStyle(color: c.muted)),
              const SizedBox(height: 8),
              _filters(),
            ],
          ),
        ),
      Padding(
        padding: const EdgeInsets.only(bottom: 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (!widget.compact)
                  const Text(
                    '今天待办',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                  ),
                Text(
                  '${_agenda.day.month}月${_agenda.day.day}日 · ${_agenda.length} 项',
                  style: TextStyle(color: c.muted, fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '紧急程度优先 · 同级按时间排列 · 已过时间置后',
              style: TextStyle(color: c.muted, fontSize: 12),
            ),
          ],
        ),
      ),
      if (_agenda.length == 0)
        Container(
          key: const Key('today-empty'),
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: c.panel.withValues(alpha: .88),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: c.line.withValues(alpha: .72)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('今天还没有待办安排'),
              const SizedBox(height: 6),
              Text(
                widget.compact
                    ? '可以新建一项，或在备忘录、日期页查看其他安排。'
                    : '可以新建一项，或从左侧查看其他日期和未设提醒的备忘录。',
                style: TextStyle(color: c.muted, fontSize: 13),
              ),
            ],
          ),
        ),
      for (final memo in _agenda.pending)
        _AgendaCard(
          memo: memo,
          elapsed: false,
          onSelect: widget.onSelect,
          compact: widget.compact,
        ),
      if (_agenda.elapsed.isNotEmpty)
        Padding(
          padding: EdgeInsets.only(
            top: _agenda.pending.isEmpty ? 0 : 12,
            bottom: 12,
          ),
          child: Text(
            '已过时间 · ${_agenda.elapsed.length} 项未完成',
            style: TextStyle(color: archiveColor(context), fontSize: 13),
          ),
        ),
      for (final memo in _agenda.elapsed)
        _AgendaCard(
          memo: memo,
          elapsed: true,
          onSelect: widget.onSelect,
          compact: widget.compact,
        ),
    ];
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 960),
        child: ListView.builder(
          key: const Key('home-agenda'),
          padding: widget.compact
              ? const EdgeInsets.fromLTRB(16, 12, 16, 20)
              : const EdgeInsets.fromLTRB(28, 28, 28, 32),
          itemCount: entries.length,
          itemBuilder: (_, index) => entries[index],
        ),
      ),
    );
  }
}

class _AgendaCard extends StatelessWidget {
  const _AgendaCard({
    required this.memo,
    required this.elapsed,
    required this.onSelect,
    this.compact = false,
  });
  final Memo memo;
  final bool elapsed;
  final bool compact;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final c = colorsOf(context);
    final gray = archiveColor(context);
    final accent = elapsed
        ? gray
        : switch (memo.priority) {
            3 => c.danger,
            2 => c.violet,
            _ => c.cyan,
          };
    final time = memo.reminderAt!.toLocal();
    final clock =
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: elapsed ? gray.withValues(alpha: .06) : c.panel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(
            color: elapsed
                ? gray.withValues(alpha: .18)
                : c.line.withValues(alpha: .72),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('agenda-row-${memo.id}'),
          onTap: () => onSelect(memo.id),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 12 : 18,
              vertical: compact ? 12 : 16,
            ),
            child: Row(
              children: [
                SizedBox(
                  width: compact ? 50 : 62,
                  child: Column(
                    children: [
                      Text(
                        clock,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          fontFeatures: const [FontFeature.tabularFigures()],
                          color: elapsed ? gray : c.cyan,
                        ),
                      ),
                      if (elapsed)
                        Text(
                          '已过时间',
                          style: TextStyle(color: gray, fontSize: 10),
                        ),
                    ],
                  ),
                ),
                Container(
                  width: 3,
                  height: 44,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: .72),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                SizedBox(width: compact ? 12 : 18),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        memo.title,
                        key: ValueKey('agenda-title-${memo.id}'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: elapsed ? gray : null,
                        ),
                      ),
                      if (memo.body.trim().isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          memo.body.trim().replaceAll('\n', ' '),
                          maxLines: compact ? 1 : 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: elapsed ? gray : c.muted,
                            fontSize: 12,
                          ),
                        ),
                      ],
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: accent.withValues(alpha: .1),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          priorityLabel(memo.priority),
                          style: TextStyle(fontSize: 11, color: accent),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  Icons.chevron_right_rounded,
                  color: elapsed ? gray : c.muted,
                  size: 20,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
