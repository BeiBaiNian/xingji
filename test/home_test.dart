import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xingji/core/models.dart';
import 'package:xingji/core/today_agenda.dart';
import 'package:xingji/ui/memo_detail.dart';
import 'package:xingji/ui/memo_filter.dart';
import 'package:xingji/ui/memo_home.dart';
import 'package:xingji/ui/theme.dart';

void main() {
  final noon = DateTime(2026, 10, 29, 12);
  Memo item(String title, int hour, {int priority = 1}) => Memo(
    title: title,
    dueAt: DateTime(2026, 10, 29, hour).toUtc(),
    priority: priority,
  );

  test('今日清单先区分过时，再按紧急程度和同级时间排序', () {
    final memos = [
      item('普通13', 13),
      item('紧急15', 15, priority: 3),
      item('重要18', 18, priority: 2),
      item('紧急14', 14, priority: 3),
      item('过时普通8', 8),
      item('过时紧急10', 10, priority: 3),
      item('普通16', 16),
      item('较低12', 12, priority: 0),
    ];
    final agenda = TodayAgenda(memos, noon);
    expect(agenda.pending.map((m) => m.title), [
      '紧急14',
      '紧急15',
      '重要18',
      '普通13',
      '普通16',
    ]);
    expect(agenda.elapsed.map((m) => m.title), ['过时紧急10', '过时普通8', '较低12']);
    expect(agenda.nextChange.toLocal(), DateTime(2026, 10, 29, 13));
    expect(memos.every((m) => !m.done && !m.deleted), isTrue);
  });

  test('本地自然日和 UTC 时间一致，排除其他日期、无时间、归档和回收站', () {
    final agenda = TodayAgenda([
      item('昨天末尾', 0).edit({
        'due_at_utc': DateTime(2026, 10, 28, 23, 59).toUtc().toIso8601String(),
      }),
      item('今天零点', 0),
      item('今天末尾', 23),
      item('明天零点', 24),
      Memo(title: '未设时间'),
      item('已完成', 13).complete(),
      item('已删除', 13).edit({'deleted_at': noon.toUtc().toIso8601String()}),
    ], noon);
    expect(agenda.pending.map((m) => m.title), ['今天末尾']);
    expect(agenda.elapsed.map((m) => m.title), ['今天零点']);
    expect(agenda.length, 2);
  });

  test('稍后提醒采用延后时间；没有今天事项时等待本地午夜', () {
    final agenda = TodayAgenda([
      item('延后到今天', 8).edit({
        'snoozed_until': DateTime(2026, 10, 29, 14).toUtc().toIso8601String(),
      }),
      item('延后到明天', 9).edit({
        'snoozed_until': DateTime(2026, 10, 30, 9).toUtc().toIso8601String(),
      }),
    ], noon);
    expect(agenda.pending.single.title, '延后到今天');
    expect(agenda.elapsed, isEmpty);
    expect(agenda.nextChange.toLocal(), DateTime(2026, 10, 29, 14));
    final later = TodayAgenda([item('明天', 24), Memo(title: '未设时间')], noon);
    expect(later.hasOpenMemos, isTrue);
    expect(later.length, 0);
    expect(later.nextChange, DateTime(2026, 10, 30));
    expect(
      TodayAgenda([item('归档', 13).complete()], noon).hasOpenMemos,
      isFalse,
    );
  });

  test('相同紧急程度和时间的记录排序稳定', () {
    final earlier = item('先创建', 14).edit({
      'created_at': noon
          .subtract(const Duration(hours: 2))
          .toUtc()
          .toIso8601String(),
    });
    final later = item('后创建', 14).edit({
      'created_at': noon
          .subtract(const Duration(hours: 1))
          .toUtc()
          .toIso8601String(),
    });
    expect(TodayAgenda([later, earlier], noon).pending.map((m) => m.id), [
      earlier.id,
      later.id,
    ]);
    expect(TodayAgenda([earlier, later], noon).pending.map((m) => m.id), [
      earlier.id,
      later.id,
    ]);
  });

  Future<void> size(WidgetTester tester, Size value) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = value;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Widget home(
    List<Memo> memos,
    DateTime Function() clock, {
    bool dark = false,
    ValueChanged<String>? select,
  }) => MaterialApp(
    theme: xingjiTheme(dark: dark),
    home: Scaffold(
      body: MemoHome(
        memos: memos,
        notice: null,
        onNew: () {},
        onSelect: select ?? (_) {},
        onFilter: (_) {},
        clock: clock,
      ),
    ),
  );

  testWidgets('到期自动变灰移到末尾，保留未完成状态，卡片可以打开详情', (tester) async {
    await size(tester, const Size(900, 800));
    var now = noon;
    final urgent = Memo(
      title: '即将到期',
      dueAt: noon.add(const Duration(seconds: 1)),
      priority: 3,
    );
    final regular = item('下午安排', 14);
    String? selected;
    await tester.pumpWidget(
      home([regular, urgent], () => now, select: (id) => selected = id),
    );
    final urgentRow = find.byKey(ValueKey('agenda-row-${urgent.id}'));
    final regularRow = find.byKey(ValueKey('agenda-row-${regular.id}'));
    expect(
      tester.getTopLeft(urgentRow).dy,
      lessThan(tester.getTopLeft(regularRow).dy),
    );
    now = noon.add(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(
      tester.getTopLeft(urgentRow).dy,
      greaterThan(tester.getTopLeft(regularRow).dy),
    );
    final title = tester.widget<Text>(
      find.byKey(ValueKey('agenda-title-${urgent.id}')),
    );
    expect(title.style!.color, archiveColor(tester.element(urgentRow)));
    expect(urgent.done, isFalse);
    await tester.tap(urgentRow);
    expect(selected, urgent.id);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('午夜自动换日，回到应用时重新比较时间', (tester) async {
    await size(tester, const Size(900, 800));
    var now = DateTime(2026, 10, 29, 23, 59, 59);
    final today = item('昨日事项', 20);
    final tomorrow = item('新的一天', 25);
    await tester.pumpWidget(home([today, tomorrow], () => now));
    expect(find.text('昨日事项'), findsOneWidget);
    expect(find.text('新的一天'), findsNothing);
    now = DateTime(2026, 10, 30);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('昨日事项'), findsNothing);
    expect(find.text('新的一天'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    now = DateTime(2026, 10, 30, 2);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    final title = tester.widget<Text>(
      find.byKey(ValueKey('agenda-title-${tomorrow.id}')),
    );
    expect(
      title.style!.color,
      archiveColor(tester.element(find.byType(MemoHome))),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('无事项居中，有未来事项时上移且明确今天为空；长内容和多条事项可滚动', (tester) async {
    await size(tester, const Size(570, 450));
    await tester.pumpWidget(home([], () => noon));
    final emptyY = tester
        .getTopLeft(find.byKey(const Key('default-page-title')))
        .dy;
    expect(find.byKey(const Key('home-empty')), findsOneWidget);
    await tester.pumpWidget(home([item('未来', 25)], () => noon));
    expect(find.byKey(const Key('today-empty')), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(const Key('default-page-title'))).dy,
      lessThan(emptyY),
    );
    final many = List.generate(
      18,
      (i) => Memo(
        title: '较长的今日待办标题需要自动换行 $i ${'内容' * 20}',
        body: '正文摘要 ${'正文' * 40}',
        dueAt: noon.add(Duration(minutes: i + 1)),
      ),
    );
    for (final dark in [false, true]) {
      await tester.pumpWidget(home(many, () => noon, dark: dark));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(ValueKey('agenda-row-${many.last.id}')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.byKey(ValueKey('agenda-row-${many.last.id}')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('圆角筛选菜单支持选中状态、切换与 Escape 取消，深浅色小窗口正常', (tester) async {
    await size(tester, const Size(570, 480));
    var selected = 'all';
    for (final dark in [false, true]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: xingjiTheme(dark: dark),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => Align(
                alignment: Alignment.topLeft,
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: SizedBox(
                    width: 246,
                    child: MemoFilterButton(
                      value: selected,
                      onChanged: (value) => setState(() => selected = value),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('memo-filter')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(ValueKey('filter-option-$selected')),
          matching: find.byIcon(Icons.check_rounded),
        ),
        findsOneWidget,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('filter-option-today')), findsNothing);
      await tester.tap(find.byKey(const Key('memo-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('filter-option-today')));
      await tester.pumpAndSettle();
      expect(selected, 'today');
      expect(tester.takeException(), isNull);
    }
  });
}
