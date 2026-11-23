import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:timezone/timezone.dart' as tz;

import '../core/app_controller.dart';
import '../core/models.dart';
import '../core/sync_engine.dart';
import '../platform/desktop_service.dart';
import 'memo_images.dart';
import 'memo_options.dart';
import 'theme.dart';

class MemoEditor extends StatefulWidget {
  const MemoEditor({
    super.key,
    required this.app,
    required this.memo,
    required this.onSaved,
  });
  final AppController app;
  final Memo memo;
  final VoidCallback onSaved;
  @override
  State<MemoEditor> createState() => _MemoEditorState();
}

class _MemoEditorState extends State<MemoEditor> {
  late Memo draft;
  final imagesKey = GlobalKey<MemoImagesState>();
  late final TextEditingController title, body;
  Timer? timer;
  Future<void>? inFlight;
  bool dirty = false, saving = false;
  bool addingImage = false;
  int revision = 0;
  String? error, baseline;
  late final Future<void> Function() flush;
  AppController get app => widget.app;

  @override
  void initState() {
    super.initState();
    draft = widget.memo;
    title = TextEditingController(text: draft.title);
    body = TextEditingController(text: draft.body);
    title.selection = TextSelection(
      baseOffset: 0,
      extentOffset: title.text.length,
    );
    baseline = app.store.get(draft.id)?.packet.operationId;
    flush = save;
    app.flushEditor = flush;
    app.submitEditor = submit;
  }

  @override
  void didUpdateWidget(covariant MemoEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!dirty && !saving && widget.memo.updatedAt != draft.updatedAt) {
      draft = widget.memo;
      title.text = draft.title;
      body.text = draft.body;
      baseline = app.store.get(draft.id)?.packet.operationId;
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    if (app.flushEditor == flush) {
      app.flushEditor = null;
      app.submitEditor = null;
    }
    title.dispose();
    body.dispose();
    super.dispose();
  }

  void changed() {
    setState(() {
      dirty = true;
      revision++;
    });
    timer?.cancel();
    timer = Timer(const Duration(milliseconds: 650), () {
      unawaited(save().catchError((Object _) {}));
    });
  }

  void edit(Json fields) {
    draft = draft.edit(fields);
    changed();
  }

  Future<void> save() async {
    timer?.cancel();
    if (inFlight != null) await inFlight;
    if (!mounted || !dirty || !app.unlocked) return;
    final future = persist();
    inFlight = future;
    try {
      await future;
    } finally {
      inFlight = null;
    }
    if (mounted && dirty) await save();
  }

  Future<void> persist() async {
    setState(() {
      saving = true;
      error = null;
    });
    final savedRevision = revision;
    var memo = draft.edit({
      'title': title.text.trim().isEmpty ? '未命名备忘录' : title.text.trim(),
      'body': body.text,
    });
    if (app.store.get(draft.id)?.packet.operationId != baseline) {
      memo = memo.edit({
        'id': uuid.v4(),
        'title': '${memo.title}（本地编辑副本）',
        'conflict_of': draft.id,
      });
    }
    try {
      await app.save(
        memo,
        copyImagesFrom: memo.id == draft.id ? null : draft.id,
      );
      if (mounted) {
        setState(() {
          baseline = app.store.get(memo.id)?.packet.operationId;
          if (revision == savedRevision) {
            draft = memo;
            dirty = false;
          }
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = safeError(e));
      rethrow;
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> submit() async {
    if (addingImage) return;
    try {
      await save();
      if (!mounted || !app.unlocked) return;
      app.saveVersion(draft.id);
      if (mounted) widget.onSaved();
    } catch (e) {
      if (mounted) setState(() => error = safeError(e));
    }
  }

  tz.TZDateTime get displayedTime => tz.TZDateTime.from(
    draft.dueAt ?? DateTime.now().add(const Duration(hours: 1)),
    tz.getLocation(draft.timezone),
  );

  void setDue(int year, int month, int day, int hour, int minute) => edit({
    'due_at_utc': tz.TZDateTime(
      tz.getLocation(draft.timezone),
      year,
      month,
      day,
      hour,
      minute,
    ).toUtc().toIso8601String(),
    'snoozed_until': null,
  });

  Future<void> chooseDate() async {
    final initial = displayedTime;
    final date = await showDatePicker(
      context: context,
      initialDate: DateTime(initial.year, initial.month, initial.day),
      firstDate: DateTime(1900),
      lastDate: DateTime(2200),
      initialEntryMode: DatePickerEntryMode.calendarOnly,
    );
    if (date != null && mounted) {
      setDue(date.year, date.month, date.day, initial.hour, initial.minute);
    }
  }

  Future<void> chooseTime() async {
    final initial = displayedTime;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: initial.hour, minute: initial.minute),
      initialEntryMode: TimePickerEntryMode.dialOnly,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (time != null && mounted) {
      setDue(initial.year, initial.month, initial.day, time.hour, time.minute);
    }
  }

  Future<void> moreOptions() async {
    final result = await memoOptionsDialog(context, draft);
    if (result != null && mounted) {
      draft = result;
      changed();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = colorsOf(context);
    final time = displayedTime;
    final compact = MediaQuery.sizeOf(context).width < 600;
    final pending = app.store.hasPending(draft.id) && app.sync.config != null;
    return ColoredBox(
      color: c.panel,
      child: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: EdgeInsets.symmetric(
                horizontal: compact ? 16 : 30,
                vertical: 24,
              ),
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 900),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '编辑备忘录',
                        style: TextStyle(color: c.muted, fontSize: 13),
                      ),
                      const SizedBox(height: 18),
                      Actions(
                        actions: {
                          if (Theme.of(context).platform ==
                              TargetPlatform.windows)
                            PasteTextIntent: _MemoPasteAction(
                              app.desktop,
                              imagesKey,
                            ),
                        },
                        child: Column(
                          children: [
                            TextField(
                              key: const Key('memo-title'),
                              controller: title,
                              autofocus: true,
                              maxLines: 2,
                              minLines: 1,
                              maxLength: 200,
                              style: const TextStyle(
                                fontSize: 26,
                                fontWeight: FontWeight.w600,
                              ),
                              decoration: const InputDecoration(
                                labelText: '标题',
                                hintText: '要记下什么？',
                                counterText: '',
                              ),
                              onChanged: (_) => changed(),
                            ),
                            const SizedBox(height: 18),
                            TextField(
                              key: const Key('memo-body'),
                              controller: body,
                              minLines: 5,
                              maxLines: 12,
                              style: const TextStyle(fontSize: 15, height: 1.7),
                              decoration: const InputDecoration(
                                labelText: '内容',
                                hintText: '补充需要记住的内容…',
                                alignLabelWithHint: true,
                              ),
                              onChanged: (_) => changed(),
                            ),
                          ],
                        ),
                      ),
                      MemoImages(
                        key: imagesKey,
                        app: app,
                        memoId: draft.id,
                        onBusyChanged: (value) =>
                            setState(() => addingImage = value),
                      ),
                      const SizedBox(height: 22),
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: c.cyan.withValues(alpha: .06),
                          border: Border.all(
                            color: c.cyan.withValues(alpha: .35),
                          ),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  Icons.notifications_active_outlined,
                                  color: c.cyan,
                                  size: 25,
                                ),
                                const SizedBox(width: 10),
                                const Expanded(
                                  child: Text(
                                    '提醒时间',
                                    style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                if (draft.dueAt != null)
                                  TextButton(
                                    onPressed: () => edit({
                                      'due_at_utc': null,
                                      'snoozed_until': null,
                                      'recurrence': 'none',
                                    }),
                                    child: const Text('取消提醒'),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 14),
                            LayoutBuilder(
                              builder: (context, constraints) => Wrap(
                                spacing: 12,
                                runSpacing: 12,
                                children: [
                                  SizedBox(
                                    width: constraints.maxWidth < 420
                                        ? constraints.maxWidth
                                        : (constraints.maxWidth - 12) / 2,
                                    child: _TimeButton(
                                      label: '日期',
                                      value: draft.dueAt == null
                                          ? '选择日期'
                                          : '${time.year}/${time.month.toString().padLeft(2, '0')}/${time.day.toString().padLeft(2, '0')}',
                                      icon: Icons.calendar_today_outlined,
                                      onPressed: chooseDate,
                                    ),
                                  ),
                                  SizedBox(
                                    width: constraints.maxWidth < 420
                                        ? constraints.maxWidth
                                        : (constraints.maxWidth - 12) / 2,
                                    child: _TimeButton(
                                      label: '时间',
                                      value: draft.dueAt == null
                                          ? '选择时间'
                                          : '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}',
                                      icon: Icons.schedule,
                                      onPressed: chooseTime,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 8,
                              runSpacing: 4,
                              children: [
                                for (final minutes in [5, 10, 30, 60])
                                  ActionChip(
                                    label: Text('$minutes 分钟后'),
                                    onPressed: () => edit({
                                      'due_at_utc': DateTime.now()
                                          .toUtc()
                                          .add(Duration(minutes: minutes))
                                          .toIso8601String(),
                                      'snoozed_until': null,
                                    }),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '时区：${draft.timezone} · 日期和时间均可单独调整',
                              style: TextStyle(fontSize: 12, color: c.muted),
                            ),
                            if (Platform.isAndroid)
                              SwitchListTile.adaptive(
                                key: const Key('memo-force-alarm'),
                                contentPadding: EdgeInsets.zero,
                                title: const Text('闹铃提醒'),
                                subtitle: Text(
                                  draft.dueAt == null
                                      ? '先选择提醒日期和时间，再开启闹铃（仅 Android 生效）'
                                      : '到点后亮屏、息屏都调用系统时钟响铃，不参与夜间免打扰顺延 · 仅 Android 生效',
                                ),
                                value: draft.forceAlarm,
                                onChanged: draft.dueAt == null
                                    ? null
                                    : (v) => edit({'force_alarm': v}),
                              ),
                            if (!app.desktop.ready || !app.desktop.allowed)
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Text(
                                  app.desktop.status,
                                  style: TextStyle(
                                    color: c.danger,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                      OutlinedButton.icon(
                        onPressed: moreOptions,
                        icon: const Icon(Icons.tune, size: 18),
                        label: const Text('更多设置 · 标签、时区、重要程度'),
                      ),
                      if (draft.tags.isNotEmpty ||
                          draft.priority != 1 ||
                          draft.recurrence != 'none')
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            '已应用可选设置，可随时修改',
                            style: TextStyle(color: c.muted, fontSize: 12),
                          ),
                        ),
                      if (draft.conflictOf != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(
                            '这是一份冲突副本，原备忘录也已保留。',
                            style: TextStyle(color: c.violet),
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
              horizontal: compact ? 16 : 30,
              vertical: 12,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text(error!, style: TextStyle(color: c.danger)),
                  ),
                Row(
                  children: [
                    Expanded(
                      child: StatusDot(
                        dirty || saving
                            ? '正在自动保存…'
                            : pending
                            ? '已自动保存 · 等待同步'
                            : '已自动保存',
                        compact: true,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Pressable(
                      child: FilledButton.icon(
                        key: const Key('save-and-return'),
                        onPressed: saving || addingImage ? null : submit,
                        icon: const Icon(Icons.check, size: 19),
                        label: const Text('保存并返回'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MemoPasteAction extends Action<PasteTextIntent> {
  _MemoPasteAction(this.desktop, this.imagesKey);

  final DesktopService desktop;
  final GlobalKey<MemoImagesState> imagesKey;

  @override
  Future<void> invoke(PasteTextIntent intent) async {
    // EditableText supplies its default action only for this invocation.
    final textAction = callingAction;
    final images = imagesKey.currentState;
    if (intent.cause != SelectionChangedCause.keyboard ||
        !HardwareKeyboard.instance.isControlPressed ||
        images == null) {
      textAction?.invoke(intent);
      return;
    }
    final field = FocusManager.instance.primaryFocus;
    bool stillEditing() => images.mounted && field?.hasPrimaryFocus == true;
    void pasteText() {
      if (stillEditing()) textAction?.invoke(intent);
    }

    if (await desktop.hasClipboardImage()) {
      if (stillEditing()) await images.pasteFromClipboard(onEmpty: pasteText);
    } else {
      pasteText();
    }
  }
}

class _TimeButton extends StatelessWidget {
  const _TimeButton({
    required this.label,
    required this.value,
    required this.icon,
    required this.onPressed,
  });
  final String label, value;
  final IconData icon;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) => Pressable(
    child: OutlinedButton(
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.all(16),
        backgroundColor: colorsOf(context).panel,
      ),
      onPressed: onPressed,
      child: Row(
        children: [
          Icon(icon, size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: colorsOf(context).muted,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
