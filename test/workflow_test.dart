import 'dart:async';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:image/image.dart' as img;
import 'package:timezone/data/latest.dart' as timezone_data;
import 'package:xingji/core/app_controller.dart';
import 'package:xingji/core/image_attachment.dart';
import 'package:xingji/core/local_store.dart';
import 'package:xingji/core/models.dart';
import 'package:xingji/core/vault_crypto.dart';
import 'package:xingji/main.dart';
import 'package:xingji/platform/desktop_service.dart';
import 'package:xingji/ui/memo_detail.dart';
import 'package:xingji/ui/memo_editor.dart';
import 'package:xingji/ui/memo_options.dart';
import 'package:xingji/ui/theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  timezone_data.initializeTimeZones();
  late LocalStore store;
  late AppController app;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() async {
    store = LocalStore(':memory:');
    app = AppController(
      store,
      await VaultCrypto.initialize(),
      'isolated-workflow',
    );
    messenger.setMockMethodCallHandler(
      DesktopService.channel,
      (call) async => switch (call.method) {
        'initialize' => {'allowed': true, 'hotkey': true, 'activation': ''},
        'notificationState' => {
          'allowed': true,
          'scheduled': 0,
          'ids': <String>[],
          'delivered': <String>[],
        },
        _ => null,
      },
    );
    await app.initialize();
    await app.create('workflow-synthetic-passphrase', trust: false);
    app.recoveryCode = null;
    await app.schedule(force: true);
  });
  tearDown(() async {
    if (app.unlocked) await app.lock().timeout(const Duration(seconds: 5));
    app.dispose();
    store.db.close();
    messenger.setMockMethodCallHandler(DesktopService.channel, null);
  });

  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(1320, 820),
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(XingJiApp(app: app));
    await tester.pumpAndSettle();
  }

  Future<void> lockWorkspace(WidgetTester tester) async {
    // Platform-channel futures cross the real setup zone and widget-test fake
    // clock. Let both queues progress before disposing the controller/store.
    var locked = false;
    app.lock().then((_) => locked = true);
    for (var i = 0; i < 50 && !locked; i++) {
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    expect(
      locked,
      true,
      reason: 'saving and native scheduling finish before closing',
    );
    await tester.pumpAndSettle();
  }

  Future<void> unmount(WidgetTester tester) async {
    await lockWorkspace(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }

  Future<void> ctrlV(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
  }

  Future<void> clipboardChanged(bool hasImage) async {
    await messenger.handlePlatformMessage(
      DesktopService.channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('clipboardImageChanged', hasImage),
      ),
      (_) {},
    );
  }

  Future<void> waitForImage(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 100 && !done(); i++) {
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
    }
    await tester.pumpAndSettle();
    expect(done(), isTrue);
  }

  testWidgets('桌面顶栏操作与底部状态均位于窗口可视范围内', (tester) async {
    await mount(tester);
    for (final tooltip in ['返回默认页', '立即同步', '设置', '锁定']) {
      final finder = find.byTooltip(tooltip);
      expect(finder, findsOneWidget);
      final rect = tester.getRect(finder);
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(1320));
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(rect.bottom, lessThanOrEqualTo(820));
    }
    final status = find.text('本地加密保存');
    expect(status, findsOneWidget);
    expect(tester.getRect(status).bottom, lessThanOrEqualTo(820));
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  test('按提醒时间排序，重要程度不插队；今天、以后与归档筛选准确', () async {
    final now = DateTime.now();
    final day = DateTime(now.year, now.month, now.day);
    final yesterday = Memo(
      title: '昨天',
      dueAt: day.subtract(const Duration(hours: 1)),
    );
    final today = Memo(title: '今天', dueAt: day.add(const Duration(hours: 22)));
    final tomorrow = Memo(
      title: '以后',
      dueAt: DateTime(now.year, now.month, now.day + 1, 10),
      pinned: true,
      priority: 3,
    );
    final undated = Memo(title: '未设时间');
    final completed = Memo(
      title: '已做过',
      dueAt: day.add(const Duration(hours: 12)),
    ).complete();
    for (final m in [tomorrow, undated, today, completed, yesterday]) {
      await app.save(m);
    }
    expect(app.visible.map((m) => m.title), ['昨天', '今天', '以后', '未设时间', '已做过']);
    app.navigate('today');
    expect(app.visible.map((m) => m.title), ['今天', '已做过']);
    app.navigate('upcoming');
    expect(app.visible.map((m) => m.title), ['以后']);
    app.navigate('completed');
    expect(app.visible.single.id, completed.id);
    expect(app.visible.single.deleted, false);
    app.navigate('unscheduled');
    expect(app.visible.single.id, undated.id);
    app.navigate('all');
    await app.snooze(yesterday, 60 * 48);
    expect(app.visible.first.id, today.id);
  });

  test('归档与下一次排程的批量写入失败时整体回滚', () async {
    final first = app.crypto.encrypt(Memo(title: '第一条'));
    final second = app.crypto.encrypt(Memo(title: '第二条'));
    store.saveLocal(second);
    expect(
      () => store.saveLocalBatch([first, second]),
      throwsA(isA<Exception>()),
    );
    expect(store.get(first.recordId), isNull);
    expect(store.all(), hasLength(1));
    expect(store.pending(), hasLength(1));
  });

  test('本机图片随重复事项归档共享，回收站恢复保图，最后一次移除释放密文', () async {
    final memo = Memo(
      title: '白板',
      recurrence: 'daily',
      dueAt: DateTime.now().toUtc(),
    );
    await app.save(memo);
    final jpeg = img.encodeJpg(img.Image(width: 12, height: 8));
    app.addImage(memo.id, (jpeg: jpeg, width: 12, height: 8));
    final id = store.imageLinks(memo.id).single.image.id;
    await app.toggleDone(memo);
    final archive = app.memos.firstWhere((m) => m.done);
    expect(app.readImage(archive.id, id), jpeg);
    // A restored date can complete the same occurrence a second time.
    await app.save(memo);
    await app.toggleDone(memo);
    expect(store.imageLinks(archive.id), hasLength(1));
    expect(store.db.select('SELECT id FROM attachments'), hasLength(1));
    await app.delete(archive);
    expect(app.readImage(archive.id, id), jpeg);
    await app.restore(app.memos.firstWhere((m) => m.id == archive.id));
    expect(app.readImage(archive.id, id), jpeg);
    await app.delete(archive);
    await app.purge(app.memos.firstWhere((m) => m.id == archive.id));
    expect(app.readImage(memo.id, id), jpeg);
    app.removeImage(memo.id, id);
    expect(store.db.select('SELECT part FROM attachment_chunks'), isEmpty);
  });

  testWidgets(
    '平台图片粘贴入口、详情预览、取消移除与锁定关闭预览',
    (tester) async {
      await mount(tester);
      await tester.tap(find.byKey(const Key('new-memo')));
      await tester.pumpAndSettle();
      final id = app.selectedId!;
      final windows = defaultTargetPlatform == TargetPlatform.windows;
      var reads = 0;
      final png = img.encodePng(img.Image(width: 24, height: 16));
      messenger.setMockMethodCallHandler(DesktopService.channel, (call) async {
        if (call.method == 'readClipboardImage') {
          reads++;
          return reads == 1 ? null : {'format': 'png', 'bytes': png};
        }
        return null;
      });
      final paste = find.text('粘贴图片');
      expect(find.text('选择图片'), windows ? findsNothing : findsOneWidget);
      expect(paste, windows ? findsNothing : findsOneWidget);
      if (windows) await clipboardChanged(true);
      Future<void> pasteIn(String field) async {
        if (windows) {
          await tester.tap(find.byKey(Key(field)));
          await ctrlV(tester);
        } else {
          await tester.ensureVisible(paste);
          await tester.tap(paste);
        }
      }

      expect(reads, 0);
      await pasteIn('memo-title');
      await tester.pumpAndSettle();
      expect(find.text('剪贴板中没有图片'), findsOneWidget);
      await pasteIn('memo-body');
      await waitForImage(tester, () => store.imageLinks(id).isNotEmpty);
      expect(reads, 2);
      expect(store.imageLinks(id), hasLength(1));
      final remove = find.byTooltip('移除第 1 张图片');
      await tester.ensureVisible(remove);
      await tester.tap(remove);
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(store.imageLinks(id), hasLength(1));
      await tester.tap(find.byKey(const Key('save-and-return')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('memo-row-$id')));
      await tester.pumpAndSettle();
      expect(find.byType(MemoDetail), findsOneWidget);
      expect(find.text('本机图片 1/9'), findsOneWidget);
      expect(remove, findsNothing);
      final thumbnail = find.byKey(
        ValueKey(store.imageLinks(id).single.image.id),
      );
      await tester.ensureVisible(thumbnail);
      await tester.tap(thumbnail);
      await tester.pumpAndSettle();
      expect(find.byTooltip('关闭预览'), findsOneWidget);
      await lockWorkspace(tester);
      expect(find.byTooltip('关闭预览'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.android,
    }),
  );

  testWidgets('Windows 标题与正文按格式分流，搜索和详情保留默认粘贴', (tester) async {
    var imageReads = 0;
    var text = '标题粘贴';
    var statusQueries = 0;
    var nativeHasImage = true;
    final pendingImage = Completer<Object?>();
    messenger.setMockMethodCallHandler(DesktopService.channel, (call) async {
      if (call.method == 'clipboardImageStatus') {
        statusQueries++;
        return {'hasImage': nativeHasImage, 'listening': true};
      }
      if (call.method == 'readClipboardImage') {
        imageReads++;
        return imageReads == 1 ? pendingImage.future : null;
      }
      if (call.method == 'initialize') return {'allowed': true};
      return null;
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') return {'text': text};
      if (call.method == 'Clipboard.hasStrings') return {'value': true};
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await app.desktop.initialize();
    await mount(tester);
    await tester.tap(find.byKey(const Key('new-memo')));
    await tester.pumpAndSettle();
    final id = app.selectedId!;
    final title = find.byKey(const Key('memo-title'));
    final body = find.byKey(const Key('memo-body'));
    final search = find.widgetWithText(TextField, '搜索备忘录');
    expect(imageReads, 0);
    expect(statusQueries, 1);

    // The clipboard already held an image when the editor opened.
    await tester.tap(title);
    await ctrlV(tester);
    await ctrlV(tester);
    expect(imageReads, 1);
    expect(find.text('正在添加图片…'), findsOneWidget);
    final bmp = img.encodeBmp(img.Image(width: 24, height: 16));
    pendingImage.complete({
      'format': 'dib',
      'bytes': Uint8List.sublistView(bmp, 14),
    });
    await waitForImage(tester, () => store.imageLinks(id).isNotEmpty);
    expect(store.imageLinks(id), hasLength(1));
    expect(tester.widget<TextField>(title).controller!.text, '新备忘录');

    nativeHasImage = false;
    await clipboardChanged(false);
    for (final field in [title, body]) {
      await tester.enterText(field, '');
      await ctrlV(tester);
      expect(tester.widget<TextField>(field).controller!.text, text);
      text = '正文粘贴';
    }
    expect(imageReads, 1);
    expect(statusQueries, 3);

    // The new copy precedes WM_CLIPBOARDUPDATE, then becomes text during the read.
    nativeHasImage = true;
    text = '刚复制的文字';
    await ctrlV(tester);
    expect(imageReads, 2);
    expect(find.text('剪贴板中没有图片'), findsOneWidget);
    expect(tester.widget<TextField>(body).controller!.text, endsWith(text));

    final jpeg = img.encodeJpg(img.Image(width: 4, height: 4));
    for (var i = 1; i < ImageAttachment.maxPerMemo; i++) {
      app.addImage(id, (jpeg: jpeg, width: 4, height: 4));
    }
    await ctrlV(tester);
    expect(find.text(ImageAttachment.countLimitMessage), findsOneWidget);
    expect(imageReads, 2);
    expect(store.imageLinks(id), hasLength(ImageAttachment.maxPerMemo));

    await tester.tap(search);
    await ctrlV(tester);
    expect(app.search, text);
    await tester.enterText(search, '');
    await tester.tap(find.byKey(const Key('save-and-return')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('memo-row-$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('detail-title')));
    await ctrlV(tester);
    expect(imageReads, 2);
    await unmount(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('Windows 粘贴错误在图片区反馈，读取中换页不会添加到其他备忘录', (tester) async {
    await mount(tester);
    final create = find.byKey(const Key('new-memo'));
    await tester.tap(create);
    await tester.pumpAndSettle();
    final id = app.selectedId!;
    final jpeg = img.encodeJpg(img.Image(width: 4, height: 4));
    app.addImage(id, (jpeg: jpeg, width: 4, height: 4));
    final saved = store.imageLinks(id).single.image;
    var reads = 0;
    final pending = Completer<Object?>();
    messenger.setMockMethodCallHandler(DesktopService.channel, (call) async {
      if (call.method != 'readClipboardImage') return null;
      return switch (++reads) {
        1 => {'format': 'dib', 'bytes': Uint8List(4)},
        2 => throw PlatformException(
          code: 'clipboard_image',
          message: '请选择 32 MiB 以内的图片',
        ),
        3 => {
          'format': 'png',
          'bytes': img.encodePng(img.Image(width: 4, height: 4)),
        },
        _ => pending.future,
      };
    });
    await clipboardChanged(true);
    await tester.tap(find.byKey(const Key('memo-title')));
    await ctrlV(tester);
    expect(find.text('剪贴板位图格式不受支持'), findsOneWidget);
    await ctrlV(tester);
    expect(find.text('请选择 32 MiB 以内的图片'), findsOneWidget);

    store.db.execute('UPDATE attachments SET byte_length=? WHERE id=?', [
      ImageAttachment.maxVaultBytes,
      saved.id,
    ]);
    await ctrlV(tester);
    await waitForImage(
      tester,
      () => find.text('本机资料库的图片已达 500 MiB 上限').evaluate().isNotEmpty,
    );
    store.db.execute('UPDATE attachments SET byte_length=? WHERE id=?', [
      saved.byteLength,
      saved.id,
    ]);
    expect(app.readImage(id, saved.id), jpeg);

    await ctrlV(tester);
    expect(reads, 4);
    await tester.tap(create);
    await tester.pumpAndSettle();
    final nextId = app.selectedId!;
    expect(nextId, isNot(id));
    pending.complete({
      'format': 'png',
      'bytes': img.encodePng(img.Image(width: 8, height: 4)),
    });
    await tester.pumpAndSettle();
    expect(store.imageLinks(nextId), isEmpty);
    expect(store.imageLinks(id).single.image.id, saved.id);
    expect(tester.takeException(), isNull);
    await unmount(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  test('升级旧客户端保存的认证删除标记后，本机旧内容与历史一并清理', () async {
    final memo = Memo(title: '旧客户端收到删除前的内容');
    await app.save(memo);
    app.saveVersion(memo.id);
    store.acknowledge(store.get(memo.id)!.packet, 1);
    final marker = app.crypto.encrypt(Memo.purgeMarker(memo.id));
    // Emulate the v1 client, which stored the marker as an ordinary trash row.
    store.applyPage([(packet: marker, revision: 2)], 2);
    expect(store.history(memo.id), isNotEmpty);
    await app.lock();
    await app.unlock('workflow-synthetic-passphrase', trust: false);
    expect(app.memos, isEmpty);
    expect(store.history(memo.id), isEmpty);
    expect(store.isPurged(memo.id), true);
    expect(store.pendingPurgeCount, 0);
  });

  test('自动保存不留版本，显式保存去重，远端自动修改不挤走本机版本', () async {
    var memo = Memo(title: '版本检查');
    for (var i = 0; i < 6; i++) {
      memo = memo.edit({'body': '输入片段 $i'});
      await app.save(memo);
    }
    expect(store.history(memo.id), isEmpty);
    app.saveVersion(memo.id);
    app.saveVersion(memo.id);
    await app.save(memo.edit({}));
    app.saveVersion(memo.id);
    expect(store.history(memo.id), hasLength(1));
    expect(app.crypto.decrypt(store.history(memo.id).single).body, '输入片段 5');
    for (final operation in store.pending()) {
      store.acknowledge(operation.packet, operation.baseRevision + 1);
    }
    final remote = app.crypto.encrypt(memo.edit({'body': '另一台设备自动保存'}));
    store.applyPage([(packet: remote, revision: 99)], 99);
    expect(store.history(memo.id), hasLength(1));
    app.saveVersion(memo.id);
    expect(store.history(memo.id), hasLength(2));
  });

  test('恢复保留完整编辑内容、当前状态和恢复前草稿，支持恢复回去', () async {
    final original = Memo(
      title: '版本 A',
      body: '旧正文',
      tags: ['旧标签'],
      checklist: [CheckItem(text: '旧清单', done: true)],
      priority: 3,
      dueAt: DateTime.utc(2030, 1, 2),
      recurrence: 'daily',
    );
    await app.save(original);
    app.saveVersion(original.id);
    final versionA = store.history(original.id).single;
    final draft = original.edit({
      'title': '未点保存的当前内容',
      'body': '仍需保留',
      'status': 'done',
      'completed_at': DateTime.utc(2026, 11, 2).toIso8601String(),
      'deleted_at': DateTime.utc(2026, 11, 2).toIso8601String(),
      'completions': 8,
      'tags': ['新标签'],
    });
    await app.save(draft);
    await app.restoreVersion(
      original.id,
      versionA,
      expectedOperationId: store.get(original.id)!.packet.operationId,
    );
    final restored = app.memos.single;
    expect(restored.title, '版本 A');
    expect(restored.tags, ['旧标签']);
    expect(restored.checklist.single.done, true);
    expect(restored.dueAt, original.dueAt);
    expect(restored.id, original.id);
    expect(restored.createdAt, original.createdAt);
    expect(restored.done && restored.deleted, true);
    expect(restored.completions, 8);
    expect(store.history(original.id), hasLength(3));
    final beforeRestore = store.history(original.id)[1];
    expect(app.crypto.decrypt(beforeRestore).body, '仍需保留');
    await app.restoreVersion(
      original.id,
      beforeRestore,
      expectedOperationId: store.get(original.id)!.packet.operationId,
    );
    expect(app.memos.single.title, '未点保存的当前内容');
  });

  test('恢复拒绝过时预览和永久删除；写入失败时版本与当前内容一起回滚', () async {
    final memo = Memo(title: '恢复边界', body: 'A');
    await app.save(memo);
    app.saveVersion(memo.id);
    final version = store.history(memo.id).single;
    final stale = store.get(memo.id)!.packet.operationId;
    await app.save(memo.edit({'body': 'B'}));
    await expectLater(
      app.restoreVersion(memo.id, version, expectedOperationId: stale),
      throwsFormatException,
    );
    final current = store.get(memo.id)!.packet.operationId;
    final pendingBefore = store.pendingCount;
    store.db.execute(
      "CREATE TRIGGER fixture_restore_failure BEFORE INSERT ON outbox BEGIN SELECT RAISE(ABORT, 'fixture'); END",
    );
    await expectLater(
      app.restoreVersion(memo.id, version, expectedOperationId: current),
      throwsA(anything),
    );
    expect(store.get(memo.id)!.packet.operationId, current);
    expect(store.history(memo.id), hasLength(1));
    expect(store.pendingCount, pendingBefore);
    store.db.execute('DROP TRIGGER fixture_restore_failure');
    await app.delete(app.memos.single);
    await app.purge(app.memos.single);
    await expectLater(
      app.restoreVersion(memo.id, version, expectedOperationId: current),
      throwsFormatException,
    );
    expect(store.history(memo.id), isEmpty);
  });

  testWidgets('新建→自动保存不跳页→显式保存返回→选择只读详情→编辑', (tester) async {
    await mount(tester);
    await tester.tap(find.byKey(const Key('new-memo')));
    await tester.pumpAndSettle();
    expect(find.byType(MemoEditor), findsOneWidget);
    await tester.enterText(find.byKey(const Key('memo-title')), '准备周会');
    await tester.enterText(find.byKey(const Key('memo-body')), '带上项目进度与问题清单');
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pumpAndSettle();
    expect(find.byType(MemoEditor), findsOneWidget);
    expect(store.history(app.memos.single.id), isEmpty);
    await tester.tap(find.byKey(const Key('save-and-return')));
    await tester.pumpAndSettle();
    expect(app.selectedId, isNull);
    expect(find.byType(MemoEditor), findsNothing);
    expect(find.text('已保存'), findsOneWidget);
    final memo = app.memos.single;
    expect(store.history(memo.id), hasLength(1));
    await tester.tap(find.byKey(ValueKey('memo-row-${memo.id}')));
    await tester.pumpAndSettle();
    expect(find.byType(MemoDetail), findsOneWidget);
    expect(find.text('带上项目进度与问题清单'), findsOneWidget);
    expect(find.text('Asia/Shanghai'), findsOneWidget);
    await tester.tap(find.byKey(const Key('edit-memo')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('memo-body')), '更新后的内容');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(app.selectedId, isNull);
    expect(app.memos.single.body, '更新后的内容');
    await unmount(tester);
  });

  testWidgets('首页今日清单独立于侧栏搜索筛选，菜单切换和卡片打开详情正常', (tester) async {
    final now = DateTime.now();
    final memo = Memo(
      title: '今天的完整安排',
      body: '卡片查看详情',
      dueAt: DateTime(now.year, now.month, now.day, 12),
    );
    await app.save(memo);
    app.navigate('upcoming');
    app.setSearch('不匹配的搜索');
    await mount(tester);
    expect(app.visible, isEmpty);
    expect(find.byKey(ValueKey('agenda-row-${memo.id}')), findsOneWidget);
    app.setSearch('');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('memo-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('filter-option-today')));
    await tester.pumpAndSettle();
    expect(app.filter, 'today');
    expect(find.byKey(ValueKey('memo-row-${memo.id}')), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('agenda-row-${memo.id}')));
    await tester.pumpAndSettle();
    expect(find.byType(MemoDetail), findsOneWidget);
    expect(find.text('卡片查看详情'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('完成灰色归档仍在默认列表；删除取消无变化，确认后可恢复', (tester) async {
    final memo = Memo(
      title: '已完成的测试事项',
      body: '保留内容',
      priority: 2,
      tags: ['工作'],
    );
    await app.save(memo);
    await mount(tester);
    await tester.tap(find.text('完成并归档'));
    await tester.pumpAndSettle();
    expect(app.visible, hasLength(1));
    expect(app.memos.single.done, true);
    expect(app.memos.single.deleted, false);
    expect(find.text('已完成 · 已归档'), findsOneWidget);
    final title = tester.widget<SelectableText>(
      find.byKey(const Key('detail-title')),
    );
    expect(
      title.style!.color,
      archiveColor(tester.element(find.byType(MemoDetail))),
    );
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.text('确认删除'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(app.memos.single.deleted, false);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认删除'));
    await tester.pumpAndSettle();
    expect(app.memos.single.deleted, true);
    expect(app.visible, isEmpty);
    app.navigate('trash');
    app.select(memo.id);
    await tester.pumpAndSettle();
    await tester.tap(find.text('恢复备忘录'));
    await tester.pumpAndSettle();
    expect(app.memos.single.deleted, false);
    expect(app.memos.single.done, true);
    await unmount(tester);
  });

  testWidgets('日期查看保留日期与条件，完成记录可回看，详情返回不丢失选择', (tester) async {
    final day = DateTime(2026, 11, 3);
    final done = Memo(title: '无提醒时间的已完成事项')
        .complete(now: day.add(const Duration(hours: 15)));
    await app.save(done);
    app.changeDateView(day: day);
    app.navigate('date');
    await mount(tester);
    expect(find.text('2026年11月3日'), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('dated-row-${done.id}')));
    await tester.pumpAndSettle();
    expect(find.byType(MemoDetail), findsOneWidget);
    await tester.tap(find.byKey(const Key('back-to-dates')));
    await tester.pumpAndSettle();
    expect(find.text('2026年11月3日'), findsOneWidget);
    await tester.tap(find.byKey(const Key('date-next')));
    await tester.pumpAndSettle();
    expect(find.text('这一天没有符合条件的备忘录'), findsOneWidget);
    await tester.tap(find.byKey(const Key('date-previous')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('date-status-open')));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('dated-row-${done.id}')), findsNothing);
    await tester.tap(find.byKey(const Key('date-basis-completed')));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('dated-row-${done.id}')), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('回收站永久删除二次确认，取消保留，确认清理并持久排队', (tester) async {
    final memo = Memo(title: '独立删除演示');
    await app.save(memo);
    await expectLater(app.purge(memo), throwsFormatException);
    await app.delete(memo);
    app.navigate('trash');
    app.select(memo.id);
    await mount(tester);
    await tester.tap(find.byKey(const Key('purge-memo')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(app.memos.single.deleted, true);
    await tester.tap(find.byKey(const Key('purge-memo')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-purge')));
    await tester.pumpAndSettle();
    expect(app.memos, isEmpty);
    expect(store.pendingPurgeCount, 1);
    expect(store.history(memo.id), isEmpty);
    await unmount(tester);
  });

  testWidgets(
    '提醒日历翻月与拨盘依次选择时分，取消保留原值，确认按事项时区保存',
    (tester) async {
      final desktop = defaultTargetPlatform == TargetPlatform.windows;
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = desktop
          ? const Size(1080, 700)
          : const Size(360, 780);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final original = DateTime.utc(2032, 1, 30, 15, 10);
      final memo = Memo(
        title: '跨时区提醒',
        timezone: 'Asia/Tokyo',
        dueAt: original,
      );
      await app.save(memo);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [Locale('zh', 'CN')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          theme: xingjiTheme(),
          home: Scaffold(
            body: MemoEditor(app: app, memo: memo, onSaved: () {}),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final l10n = MaterialLocalizations.of(
        tester.element(find.byType(MemoEditor)),
      );
      final pointer = desktop
          ? PointerDeviceKind.mouse
          : PointerDeviceKind.touch;
      Future<void> press(Finder finder) async {
        await tester.ensureVisible(finder);
        await tester.tap(finder, kind: pointer);
        await tester.pumpAndSettle();
      }

      for (final confirm in [false, true]) {
        await press(find.text('2032/01/31'));
        final dialog = find.byType(DatePickerDialog);
        expect(
          tester.widget<DatePickerDialog>(dialog).initialEntryMode,
          DatePickerEntryMode.calendarOnly,
        );
        expect(find.byType(CalendarDatePicker), findsOneWidget);
        expect(find.byTooltip(l10n.inputDateModeButtonLabel), findsNothing);
        await press(find.byTooltip(l10n.nextMonthTooltip));
        await press(
          find.descendant(of: dialog, matching: find.text('8')).hitTestable(),
        );
        await press(
          find.text(confirm ? l10n.okButtonLabel : l10n.cancelButtonLabel),
        );
        await tester.pump(const Duration(milliseconds: 700));
        expect(
          app.memos.single.dueAt,
          confirm ? DateTime.utc(2032, 2, 7, 15, 10) : original,
        );
      }
      expect(find.text('2032/02/08'), findsOneWidget);

      for (final confirm in [false, true]) {
        await press(find.text('00:10'));
        final dialog = find.byType(TimePickerDialog);
        expect(
          tester.widget<TimePickerDialog>(dialog).initialEntryMode,
          TimePickerEntryMode.dialOnly,
        );
        expect(find.byTooltip(l10n.inputTimeModeButtonLabel), findsNothing);
        expect(
          find.descendant(of: dialog, matching: find.byType(EditableText)),
          findsNothing,
        );
        final dial = find.descendant(
          of: dialog,
          matching: find.byWidgetPredicate(
            (w) =>
                w is GestureDetector &&
                w.onPanStart != null &&
                w.onTapUp != null,
          ),
        );
        final center = tester.getCenter(dial);
        await tester.tapAt(
          center + const Offset(40, 0),
          kind: pointer,
        ); // Inner ring, 15:00.
        await tester.pumpAndSettle();
        await tester.tapAt(
          center - const Offset(64, 0),
          kind: pointer,
        ); // Minute 45.
        await tester.pumpAndSettle();
        await press(
          find.text(confirm ? l10n.okButtonLabel : l10n.cancelButtonLabel),
        );
        await tester.pump(const Duration(milliseconds: 700));
        expect(
          app.memos.single.dueAt,
          confirm
              ? DateTime.utc(2032, 2, 8, 6, 45)
              : DateTime.utc(2032, 2, 7, 15, 10),
        );
      }
      expect(find.text('15:45'), findsOneWidget);
      expect(app.memos.single.timezone, 'Asia/Tokyo');
      expect(tester.takeException(), isNull);
      await unmount(tester);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.android,
    }),
  );

  testWidgets('高级设置默认隐藏；取消不提交；弹窗在小窗口滚动且深浅模式不溢出', (tester) async {
    await mount(tester, size: const Size(900, 580));
    await tester.tap(find.byKey(const Key('new-memo')));
    await tester.pumpAndSettle();
    expect(find.byType(MemoOptionsDialog), findsNothing);
    final options = find.text('更多设置 · 标签、时区、重要程度');
    await tester.ensureVisible(options);
    await tester.tap(options);
    await tester.pumpAndSettle();
    expect(find.byType(MemoOptionsDialog), findsOneWidget);
    await tester.enterText(find.byKey(const Key('options-tags')), '未提交');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(app.memos.single.tags, isEmpty);
    await tester.tap(options);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('options-tags')), '工作，灵感');
    await tester.tap(find.text('应用设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-and-return')));
    await tester.pumpAndSettle();
    expect(app.memos.single.tags, ['工作', '灵感']);
    await app.toggleTheme();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('memo-row-${app.memos.single.id}')));
    await tester.pumpAndSettle();
    expect(find.byType(MemoDetail), findsOneWidget);
    expect(find.text('工作'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });
}
