import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_controller.dart';
import '../core/models.dart';
import '../core/sync_engine.dart';
import 'dialogs.dart';
import 'memo_actions.dart';
import 'memo_detail.dart';
import 'memo_dates.dart';
import 'memo_editor.dart';
import 'memo_filter.dart';
import 'memo_home.dart';
import 'theme.dart';

class Workspace extends StatefulWidget {
  const Workspace({super.key, required this.app});
  final AppController app;
  @override
  State<Workspace> createState() => _WorkspaceState();
}

class _WorkspaceState extends State<Workspace> {
  final searchFocus = FocusNode();
  final searchText = TextEditingController();
  String? editingId, homeNotice;
  bool working = false;
  AppController get app => widget.app;

  @override
  void initState() {
    super.initState();
    app.addListener(changed);
  }

  @override
  void dispose() {
    app.removeListener(changed);
    searchFocus.dispose();
    searchText.dispose();
    super.dispose();
  }

  void changed() {
    if (searchText.text != app.search) searchText.text = app.search;
    if (app.message == 'new') {
      app.message = null;
      unawaited(newMemo());
    }
  }

  Future<void> action(Future<void> Function() work) async {
    if (working) return;
    working = true;
    try {
      await work();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(safeError(e))));
      }
    } finally {
      working = false;
    }
  }

  void home({String? notice}) {
    if (!mounted) return;
    setState(() {
      editingId = null;
      homeNotice = notice;
    });
    if (app.filter == 'date') {
      app.navigate('all');
    } else {
      app.select(null);
    }
  }

  Future<void> newMemo() => action(() async {
    await app.flushEditor?.call();
    app.setSearch('');
    app.navigate('all');
    final memo = Memo(title: '新备忘录');
    await app.save(memo);
    if (mounted) {
      setState(() {
        editingId = memo.id;
        homeNotice = null;
      });
    }
  });
  Future<void> select(String id) => action(() async {
    await app.flushEditor?.call();
    if (mounted) setState(() => editingId = null);
    app.select(id);
  });
  Future<void> navigate(String filter) => action(() async {
    await app.flushEditor?.call();
    if (mounted) {
      setState(() {
        editingId = null;
        homeNotice = null;
      });
    }
    app.navigate(filter);
  });
  Future<void> toggle(Memo memo) => action(() async {
    await app.flushEditor?.call();
    if (mounted) setState(() => editingId = null);
    await app.toggleDone(app.memos.firstWhere((m) => m.id == memo.id));
  });
  Future<void> remove(Memo memo) => action(() async {
    await app.flushEditor?.call();
    if (!mounted) return;
    if (await deleteMemoWithConfirmation(
      context,
      app,
      app.memos.firstWhere((m) => m.id == memo.id),
    )) {
      home(notice: '已移入回收站');
    }
  });
  Future<void> saveAndReturn() => action(() async {
    await app.submitEditor?.call();
  });

  Future<void> purge(Memo memo) => action(() async {
    await app.flushEditor?.call();
    if (!mounted) return;
    if (await purgeMemoWithConfirmation(context, app, memo) && mounted) {
      home(notice: '本机内容已永久删除');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('永久删除已提交，数据库清理结果请查看顶部同步状态。')),
      );
    }
  });

  @override
  Widget build(BuildContext context) {
    final c = colorsOf(context);
    final visible = app.visible;
    final selected = app.selected;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): newMemo,
        const SingleActivator(LogicalKeyboardKey.keyS, control: true):
            saveAndReturn,
        const SingleActivator(LogicalKeyboardKey.keyL, control: true): () =>
            action(app.lock),
        const SingleActivator(LogicalKeyboardKey.keyF, control: true):
            searchFocus.requestFocus,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: AppAmbient(
            child: Column(
              children: [
                Container(
                  height: 68,
                  padding: const EdgeInsets.symmetric(horizontal: 22),
                  decoration: BoxDecoration(
                    color: c.panel.withValues(alpha: .82),
                    border: Border(
                      bottom: BorderSide(color: c.line.withValues(alpha: .72)),
                    ),
                  ),
                  child: Row(
                    children: [
                      const StarMark(size: 38),
                      const SizedBox(width: 12),
                      const Text(
                        '星记',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -.3,
                        ),
                      ),
                      const SizedBox(width: 20),
                      Expanded(
                        child: StatusDot(
                          app.sync.status,
                          color: app.sync.hasError ? c.danger : c.cyan,
                        ),
                      ),
                      IconButton(
                        tooltip: '返回默认页',
                        onPressed: () => action(() async {
                          await app.flushEditor?.call();
                          home();
                        }),
                        icon: const Icon(Icons.home_outlined, size: 22),
                      ),
                      IconButton(
                        tooltip: '立即同步',
                        onPressed: app.sync.config == null
                            ? null
                            : app.sync.sync,
                        icon: const Icon(Icons.sync_rounded, size: 21),
                      ),
                      TextButton.icon(
                        onPressed: app.toggleTheme,
                        icon: Icon(
                          app.darkMode
                              ? Icons.light_mode_outlined
                              : Icons.dark_mode_outlined,
                          size: 18,
                        ),
                        label: Text(app.darkMode ? '浅色' : '深色'),
                      ),
                      IconButton(
                        tooltip: '设置',
                        onPressed: () => settingsDialog(context, app),
                        icon: const Icon(Icons.settings_outlined, size: 21),
                      ),
                      IconButton(
                        tooltip: '锁定',
                        onPressed: () => action(app.lock),
                        icon: const Icon(Icons.lock_outline_rounded, size: 20),
                      ),
                    ],
                  ),
                ),
                const Divider(),
                if (app.message != null && app.message != 'new')
                  MaterialBanner(
                    content: Text(app.message!),
                    actions: [
                      TextButton(
                        onPressed: app.dismissMessage,
                        child: const Text('知道了'),
                      ),
                    ],
                  ),
                Expanded(
                  child: Row(
                    children: [
                      SizedBox(
                        width: 330,
                        child: Column(
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(18, 18, 18, 8),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: MemoFilterButton(
                                      value: app.filter,
                                      onChanged: (v) => unawaited(navigate(v)),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Pressable(
                                    child: IconButton.filled(
                                      key: const Key('new-memo'),
                                      tooltip: '新建备忘录',
                                      onPressed: newMemo,
                                      icon: const Icon(Icons.add),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 18,
                              ),
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  app.filter == 'date'
                                      ? '按所选日期和状态查看'
                                      : app.filter == 'completed'
                                      ? '按完成时间排列'
                                      : '按提醒时间排列 · 已完成置后',
                                  style: TextStyle(
                                    color: c.muted,
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(
                                18,
                                14,
                                18,
                                16,
                              ),
                              child: TextField(
                                controller: searchText,
                                focusNode: searchFocus,
                                onChanged: app.setSearch,
                                decoration: const InputDecoration(
                                  hintText: '搜索备忘录',
                                  prefixIcon: Icon(Icons.search, size: 20),
                                  isDense: true,
                                ),
                              ),
                            ),
                            Expanded(
                              child: visible.isEmpty
                                  ? Center(
                                      child: Text(
                                        app.search.isEmpty
                                            ? '这里还没有备忘录'
                                            : '没有匹配的内容',
                                        style: TextStyle(color: c.muted),
                                      ),
                                    )
                                  : ListView.builder(
                                      padding: const EdgeInsets.fromLTRB(
                                        10,
                                        0,
                                        10,
                                        12,
                                      ),
                                      itemCount: visible.length,
                                      itemBuilder: (_, index) {
                                        final memo = visible[index];
                                        final gray = archiveColor(context);
                                        final active = selected?.id == memo.id;
                                        final expired =
                                            !memo.done &&
                                            memo.reminderAt != null &&
                                            memo.reminderAt!.isBefore(
                                              DateTime.now(),
                                            );
                                        return Padding(
                                          padding: const EdgeInsets.only(
                                            bottom: 7,
                                          ),
                                          child: Material(
                                            color: memo.done
                                                ? gray.withValues(
                                                    alpha: active ? .15 : .06,
                                                  )
                                                : active
                                                ? c.cyan.withValues(alpha: .10)
                                                : c.panel.withValues(
                                                    alpha: .42,
                                                  ),
                                            shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(14),
                                              side: BorderSide(
                                                color: active
                                                    ? c.cyan.withValues(
                                                        alpha: .24,
                                                      )
                                                    : c.line.withValues(
                                                        alpha: .42,
                                                      ),
                                              ),
                                            ),
                                            child: InkWell(
                                              key: ValueKey(
                                                'memo-row-${memo.id}',
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(14),
                                              onTap: () => select(memo.id),
                                              child: Padding(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      vertical: 12,
                                                      horizontal: 8,
                                                    ),
                                                child: Row(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Checkbox(
                                                      value: memo.done,
                                                      activeColor: memo.done
                                                          ? gray
                                                          : null,
                                                      onChanged: memo.deleted
                                                          ? null
                                                          : (_) => toggle(memo),
                                                    ),
                                                    Expanded(
                                                      child: Padding(
                                                        padding:
                                                            const EdgeInsets.only(
                                                              top: 3,
                                                            ),
                                                        child: Column(
                                                          crossAxisAlignment:
                                                              CrossAxisAlignment
                                                                  .start,
                                                          children: [
                                                            Text(
                                                              memo.title,
                                                              maxLines: 2,
                                                              overflow:
                                                                  TextOverflow
                                                                      .ellipsis,
                                                              style: TextStyle(
                                                                fontSize: 14,
                                                                color: memo.done
                                                                    ? gray
                                                                    : null,
                                                                fontWeight:
                                                                    active
                                                                    ? FontWeight
                                                                          .w600
                                                                    : FontWeight
                                                                          .w400,
                                                              ),
                                                            ),
                                                            const SizedBox(
                                                              height: 6,
                                                            ),
                                                            Text(
                                                              memo.done
                                                                  ? '已归档 · ${dateLabel(memo.completedAt)}'
                                                                  : memo.reminderAt ==
                                                                        null
                                                                  ? '未设提醒'
                                                                  : dateLabel(
                                                                      memo.reminderAt,
                                                                    ),
                                                              maxLines: 2,
                                                              overflow:
                                                                  TextOverflow
                                                                      .ellipsis,
                                                              style: TextStyle(
                                                                fontSize: 11,
                                                                color: memo.done
                                                                    ? gray
                                                                    : expired
                                                                    ? c.danger
                                                                    : c.muted,
                                                              ),
                                                            ),
                                                            if (memo.conflictOf !=
                                                                null)
                                                              Text(
                                                                '冲突副本',
                                                                style: TextStyle(
                                                                  fontSize: 11,
                                                                  color:
                                                                      c.violet,
                                                                ),
                                                              ),
                                                          ],
                                                        ),
                                                      ),
                                                    ),
                                                    IconButton(
                                                      tooltip: memo.deleted
                                                          ? '永久删除备忘录'
                                                          : '删除备忘录',
                                                      icon: Icon(
                                                        memo.deleted
                                                            ? Icons
                                                                  .delete_forever_outlined
                                                            : Icons
                                                                  .delete_outline,
                                                        size: 17,
                                                        color: memo.deleted
                                                            ? c.danger
                                                            : c.muted,
                                                      ),
                                                      onPressed: () =>
                                                          memo.deleted
                                                          ? purge(memo)
                                                          : remove(memo),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                            ),
                          ],
                        ),
                      ),
                      VerticalDivider(width: 1, color: c.line),
                      Expanded(
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 160),
                          switchInCurve: Curves.easeOut,
                          switchOutCurve: Curves.easeOut,
                          child: selected == null
                              ? app.filter == 'date'
                                    ? MemoDates(
                                        key: const ValueKey('dates'),
                                        app: app,
                                        onSelect: select,
                                      )
                                    : MemoHome(
                                        key: ValueKey('home-${app.filter}'),
                                        notice: homeNotice,
                                        memos: app.memos,
                                        onNew: newMemo,
                                        onSelect: select,
                                        onFilter: navigate,
                                      )
                              : editingId == selected.id &&
                                    !selected.deleted &&
                                    !selected.done
                              ? MemoEditor(
                                  key: ValueKey('edit-${selected.id}'),
                                  app: app,
                                  memo: selected,
                                  onSaved: () => home(notice: '已保存'),
                                )
                              : MemoDetail(
                                  key: ValueKey('detail-${selected.id}'),
                                  app: app,
                                  memo: selected,
                                  onEdit: () =>
                                      setState(() => editingId = selected.id),
                                  onToggle: () => toggle(selected),
                                  onDelete: () => remove(selected),
                                  onPurge: () => purge(selected),
                                  onBackToDates: app.filter == 'date'
                                      ? () => app.select(null)
                                      : null,
                                  onRestore: () => action(() async {
                                    await app.restore(selected);
                                    app.navigate('all');
                                    home(notice: '已恢复');
                                  }),
                                  onStopRepeat: () => action(() async {
                                    await app.save(
                                      selected.complete(stopSeries: true),
                                    );
                                  }),
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  height: 32,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  decoration: BoxDecoration(
                    color: c.panel.withValues(alpha: .88),
                    border: Border(
                      top: BorderSide(color: c.line.withValues(alpha: .72)),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.shield_outlined, size: 13, color: c.muted),
                      const SizedBox(width: 6),
                      Text(
                        '本地加密保存',
                        style: TextStyle(fontSize: 11, color: c.muted),
                      ),
                      const Spacer(),
                      Flexible(
                        child: StatusDot(
                          app.desktop.status,
                          color: app.desktop.allowed ? c.cyan : c.danger,
                          compact: true,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
