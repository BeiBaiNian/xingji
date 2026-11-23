// Development-only fixture generator. Not included in the installed app.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:timezone/data/latest.dart' as timezone_data;
import 'package:xingji/core/app_controller.dart';
import 'package:xingji/core/local_store.dart';
import 'package:xingji/core/models.dart';
import 'package:xingji/core/vault_crypto.dart';
import 'package:xingji/platform/desktop_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  timezone_data.initializeTimeZones();
  test('create a new, explicitly isolated UI preview', () async {
    const profile = String.fromEnvironment('XINGJI_UI_PROFILE');
    // Fixtures stay inside an ignored .test-data directory: either the clone's
    // own one, or the sibling one used by a personal workspace layout.
    final allowedRoots = [
      p.normalize(p.join(Directory.current.path, '.test-data')),
      p.normalize(p.join(Directory.current.parent.path, '.test-data')),
    ];
    final target = p.normalize(profile);
    if (profile.isEmpty || !allowedRoots.any((root) => p.isWithin(root, target))) {
      throw StateError(
        'An explicit profile under .test-data is required',
      );
    }
    if (Directory(profile).existsSync()) {
      throw StateError('Never overwrite an existing preview');
    }
    Directory(profile).createSync(recursive: true);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
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
    final store = LocalStore(p.join(profile, 'vault.sqlite3'));
    final app = AppController(store, await VaultCrypto.initialize(), profile);
    await app.initialize();
    await app.create('Synthetic-UI-preview-only-2026', trust: true);
    final now = DateTime.now();
    final fixtures = [
      Memo(
        title: '整理明天的项目讨论',
        body: '整理本周的进展，列出需要确认的事项。\n\n把下一步行动写清楚，讨论时就不容易遗漏。',
        dueAt: now.add(const Duration(hours: 12)),
        tags: ['工作', '项目'],
        priority: 2,
        checklist: [
          CheckItem(text: '整理当前进展', done: true),
          CheckItem(text: '列出需要讨论的问题'),
        ],
      ),
      Memo(
        title: '留半小时读书',
        body: '接着读昨天的章节，记下一个有意思的想法。',
        dueAt: now.add(const Duration(hours: 18)),
        tags: ['生活'],
      ),
      Memo(title: '周末散步的路线', body: '找一条安静的路线，带上相机。'),
      Memo(
        title: '整理桌面与笔记',
        body: '文件已整理，保留这条记录以便回顾。',
        tags: ['生活'],
        dueAt: now.subtract(const Duration(hours: 2)),
      ).complete(now: now.subtract(const Duration(hours: 1))),
    ];
    for (final memo in fixtures) {
      await app.save(memo);
    }
    await app.schedule(force: true);
    await app.lock();
    app.dispose();
    store.db.close();
    messenger.setMockMethodCallHandler(DesktopService.channel, null);
  });
}
