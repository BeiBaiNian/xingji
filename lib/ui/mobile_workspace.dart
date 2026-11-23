import 'dart:async';

import 'package:flutter/material.dart';

import '../core/app_controller.dart';
import '../core/models.dart';
import '../core/sync_engine.dart';
import 'memo_actions.dart';
import 'memo_dates.dart';
import 'memo_detail.dart';
import 'memo_editor.dart';
import 'memo_filter.dart';
import 'memo_home.dart';
import 'mobile_settings.dart';
import 'theme.dart';

class MobileWorkspace extends StatefulWidget {
  const MobileWorkspace({super.key, required this.app});
  final AppController app;
  @override
  State<MobileWorkspace> createState() => _MobileWorkspaceState();
}

class _MobileWorkspaceState extends State<MobileWorkspace>
    with WidgetsBindingObserver {
  AppController get app => widget.app;
  final search = TextEditingController();
  int tab = 0;
  String? editing, notice;
  bool working = false;
  Future<void> lifecycle = Future.value();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    app.addListener(changed);
  }

  void changed() {
    if (search.text != app.search) search.text = app.search;
    if (app.message == 'new') {
      app.message = null;
      unawaited(newMemo());
    }
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.resumed) {
      lifecycle = lifecycle
          .then(
            (_) => state == AppLifecycleState.paused
                ? app.suspendMobile()
                : app.resumeMobile(),
          )
          .catchError((Object _) {
            // Durable local edits remain queued if the network changes on resume.
          });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    app.removeListener(changed);
    search.dispose();
    super.dispose();
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

  Future<void> newMemo() => action(() async {
    await app.flushEditor?.call();
    app.setSearch('');
    final memo = Memo(title: '新备忘录');
    await app.save(memo);
    app.select(memo.id);
    if (mounted) {
      setState(() {
        editing = memo.id;
        notice = null;
      });
    }
  });
  Future<void> back() => action(() async {
    await app.flushEditor?.call();
    if (!mounted) return;
    setState(() {
      editing = null;
    });
    if (app.selectedId != null) {
      app.select(null);
    } else {
      setState(() => tab = 0);
      app.navigate('all');
    }
  });
  Future<void> saved() => action(() async {
    await app.flushEditor?.call();
    if (!mounted) return;
    FocusScope.of(context).unfocus();
    setState(() {
      tab = 0;
      editing = null;
      notice = '已保存';
    });
    app.navigate('all');
  });
  Future<void> navigate(String filter) => action(() async {
    await app.flushEditor?.call();
    if (!mounted) return;
    setState(() {
      editing = null;
      tab = filter == 'date' ? 2 : 1;
      notice = null;
    });
    app.navigate(filter);
  });
  Future<void> changeTab(int value) => action(() async {
    await app.flushEditor?.call();
    if (!mounted) return;
    setState(() {
      editing = null;
      tab = value;
    });
    app.setSearch('');
    app.navigate(value == 2 ? 'date' : 'all');
  });
  Future<void> select(String id) => action(() async {
    await app.flushEditor?.call();
    if (mounted) setState(() => editing = null);
    app.select(id);
  });
  Future<void> remove(Memo memo, {bool permanent = false}) => action(() async {
    await app.flushEditor?.call();
    if (!mounted) return;
    final removed = permanent
        ? await purgeMemoWithConfirmation(context, app, memo)
        : await deleteMemoWithConfirmation(context, app, memo);
    if (removed && mounted) {
      setState(() => editing = null);
      app.select(null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(permanent ? '本机内容已移除，数据库清理进度见同步状态。' : '已移入回收站')),
      );
    }
  });

  @override
  Widget build(BuildContext context) {
    final memo = app.selected;
    final detail = memo != null;
    final c = colorsOf(context);
    return PopScope(
      canPop: !detail && editing == null && tab == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(back());
      },
      child: Scaffold(
        appBar: AppBar(
          toolbarHeight: 56,
          leading: detail
              ? IconButton(
                  key: const Key('mobile-back'),
                  tooltip: '保存并返回',
                  onPressed: back,
                  icon: const Icon(Icons.arrow_back),
                )
              : null,
          title: detail
              ? Text(editing != null ? '编辑' : '备忘录详情')
              : const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    StarMark(size: 30),
                    SizedBox(width: 8),
                    Text('星记'),
                  ],
                ),
          actions: [
            IconButton(
              tooltip: app.darkMode ? '切换浅色' : '切换深色',
              onPressed: app.toggleTheme,
              icon: Icon(
                app.darkMode
                    ? Icons.light_mode_outlined
                    : Icons.dark_mode_outlined,
              ),
            ),
            IconButton(
              key: const Key('mobile-settings'),
              tooltip: '设置',
              icon: const Icon(Icons.settings_outlined),
              onPressed: () => action(() async {
                await app.flushEditor?.call();
                if (context.mounted) {
                  await Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => MobileSettings(app: app),
                    ),
                  );
                }
              }),
            ),
          ],
        ),
        body: AppAmbient(
          child: SafeArea(
            top: false,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                  child: GlassPanel(
                    radius: 14,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () => action(app.sync.sync),
                        borderRadius: BorderRadius.circular(10),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(
                            children: [
                              Icon(
                                app.sync.hasError
                                    ? Icons.cloud_off_outlined
                                    : Icons.sync_rounded,
                                size: 17,
                                color: app.sync.hasError ? c.danger : c.cyan,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  app.sync.status,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: c.muted,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (!app.desktop.allowed || !app.desktop.exact)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        Icon(
                          Icons.notifications_outlined,
                          size: 18,
                          color: c.muted,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            !app.desktop.allowed
                                ? '通知未开启，提醒可能无法送达'
                                : '允许准时提醒，避免系统延后',
                            style: TextStyle(fontSize: 12, color: c.muted),
                          ),
                        ),
                        TextButton(
                          onPressed: () => action(
                            !app.desktop.allowed
                                ? app.desktop.openNotificationSettings
                                : app.desktop.exactSettings,
                          ),
                          child: const Text('设置'),
                        ),
                      ],
                    ),
                  ),
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
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 160),
                    switchInCurve: Curves.easeOut,
                    switchOutCurve: Curves.easeOut,
                    child: memo != null
                        ? editing == memo.id && !memo.done && !memo.deleted
                              ? MemoEditor(
                                  key: ValueKey('mobile-edit-${memo.id}'),
                                  app: app,
                                  memo: memo,
                                  onSaved: saved,
                                )
                              : MemoDetail(
                                  key: ValueKey('mobile-detail-${memo.id}'),
                                  app: app,
                                  memo: memo,
                                  onEdit: () =>
                                      setState(() => editing = memo.id),
                                  onToggle: () =>
                                      action(() => app.toggleDone(memo)),
                                  onDelete: () => remove(memo),
                                  onPurge: () => remove(memo, permanent: true),
                                  onRestore: () =>
                                      action(() => app.restore(memo)),
                                  onStopRepeat: () => action(
                                    () => app.save(
                                      memo.complete(stopSeries: true),
                                    ),
                                  ),
                                  onBackToDates: tab == 2 ? back : null,
                                )
                        : tab == 0
                        ? MemoHome(
                            key: const ValueKey('mobile-home'),
                            memos: app.memos,
                            notice: notice,
                            onNew: newMemo,
                            onSelect: select,
                            onFilter: navigate,
                            compact: true,
                          )
                        : tab == 2
                        ? MemoDates(
                            key: const ValueKey('mobile-dates-page'),
                            app: app,
                            onSelect: select,
                          )
                        : KeyedSubtree(
                            key: ValueKey('mobile-list-${app.filter}'),
                            child: _list(context),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
        floatingActionButton: !detail && tab != 0
            ? FloatingActionButton(
                key: const Key('mobile-new'),
                onPressed: newMemo,
                tooltip: '新建备忘录',
                elevation: 2,
                backgroundColor: c.cyan,
                foregroundColor: Theme.of(context).brightness == Brightness.dark
                    ? c.ink
                    : Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Icon(Icons.add),
              )
            : null,
        bottomNavigationBar: detail
            ? null
            : DecoratedBox(
                decoration: BoxDecoration(
                  color: c.panel.withValues(alpha: .92),
                  border: Border(
                    top: BorderSide(color: c.line.withValues(alpha: .72)),
                  ),
                ),
                child: NavigationBar(
                  height: 68,
                  backgroundColor: Colors.transparent,
                  selectedIndex: tab,
                  onDestinationSelected: changeTab,
                  destinations: const [
                    NavigationDestination(
                      key: Key('mobile-today'),
                      icon: Icon(Icons.today_outlined),
                      label: '今天',
                    ),
                    NavigationDestination(
                      key: Key('mobile-memos'),
                      icon: Icon(Icons.notes_rounded),
                      label: '备忘录',
                    ),
                    NavigationDestination(
                      key: Key('mobile-dates'),
                      icon: Icon(Icons.calendar_month_outlined),
                      label: '日期',
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _list(BuildContext context) {
    final rows = app.visible;
    final c = colorsOf(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              MemoFilterButton(value: app.filter, onChanged: navigate),
              const SizedBox(height: 12),
              TextField(
                controller: search,
                onChanged: app.setSearch,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: '搜索备忘录',
                  isDense: true,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: rows.isEmpty
              ? Center(
                  child: Text('这里还没有备忘录', style: TextStyle(color: c.muted)),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 88),
                  itemCount: rows.length,
                  itemBuilder: (context, index) {
                    final memo = rows[index];
                    final color = memo.done ? archiveColor(context) : c.cyan;
                    return Card(
                      margin: const EdgeInsets.only(bottom: 10),
                      elevation: 0,
                      color: memo.done ? color.withValues(alpha: .07) : c.panel,
                      child: ListTile(
                        key: ValueKey('mobile-row-${memo.id}'),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 6,
                        ),
                        leading: memo.deleted
                            ? Icon(Icons.delete_outline, color: c.muted)
                            : Checkbox(
                                value: memo.done,
                                onChanged: (_) =>
                                    action(() => app.toggleDone(memo)),
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
                          memo.done
                              ? '已归档 · ${dateLabel(memo.completedAt ?? memo.updatedAt)}'
                              : memo.reminderAt == null
                              ? '未设提醒'
                              : dateLabel(memo.reminderAt!),
                          style: TextStyle(color: c.muted, fontSize: 12),
                        ),
                        onTap: () => select(memo.id),
                        trailing: const Icon(Icons.chevron_right, size: 20),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
