// Isolated Windows peer for Android interoperability QA. Never uses port 5432.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xingji/core/local_store.dart';
import 'package:xingji/core/models.dart';
import 'package:xingji/core/sync_engine.dart';
import 'package:xingji/core/vault_crypto.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('Android QA: isolated Windows peer', () async {
    const phase = String.fromEnvironment('QA_PHASE', defaultValue: 'prepare');
    // QA state stays inside an ignored .test-data directory of the clone.
    final root = Directory('${Directory.current.path}/.test-data')
      ..createSync(recursive: true);
    final store = LocalStore('${root.path}/android-peer.sqlite');
    final crypto = await VaultCrypto.initialize();
    final sync = SyncEngine(store, crypto, onChanged: () {}, onState: () {});
    sync.config = const ConnectionConfig(
      host: '127.0.0.1',
      port: 55473,
      database: 'postgres',
      username: 'test_device_a',
      tls: false,
    );
    try {
      if (store.envelope == null) {
        expect(phase, 'prepare');
        final created = await crypto.create('Android-QA-only-2026');
        store.setMeta('envelope', jsonEncode(created.envelope));
        store.saveLocal(
          crypto.encrypt(
            Memo(
              title: '电脑传来的备忘录',
              body: 'QA_PC_CIPHERTEXT_ONLY',
              tags: ['跨端验证'],
              priority: 2,
            ),
          ),
        );
        store.saveLocal(
          crypto.encrypt(Memo(title: 'QA_TRASH', deletedAt: DateTime.now())),
        );
      } else {
        await crypto.unlock(store.envelope!, 'Android-QA-only-2026');
      }
      await sync.sync();
      expect(sync.hasError, false, reason: sync.status);
      if (phase == 'background') {
        store.saveLocal(
          crypto.encrypt(
            Memo(
              title: '后台闹铃验证031',
              body: 'ISOLATED_BACKGROUND_ALARM_TEST',
              dueAt: DateTime.now().add(const Duration(seconds: 90)),
            ),
          ),
        );
        await sync.sync();
        expect(sync.hasError, false, reason: sync.status);
      }
      if (phase == 'verify') {
        final records = store
            .all()
            .map((r) => crypto.decrypt(r.packet))
            .toList();
        expect(records.any((m) => m.title == '电脑传来的备忘录' && m.done), true);
        expect(records.any((m) => m.title == '手机提醒验证'), true);
        expect(records.any((m) => m.title == 'QA_TRASH'), false);
        expect(store.purgeMarkers(), isNotEmpty);
        // This is pulled by Android's headless background engine.
        store.saveLocal(
          crypto.encrypt(
            Memo(
              title: '后台同步验证',
              body: 'QA_BACKGROUND_CIPHERTEXT_ONLY',
              dueAt: DateTime.now().add(const Duration(minutes: 5)),
              tags: ['后台'],
            ),
          ),
        );
        await sync.sync();
        expect(sync.hasError, false, reason: sync.status);
      }
      await File('${root.path}/android-qa-defines.json')
          .writeAsString(jsonEncode({'QA_VAULT': crypto.vaultId}));
    } finally {
      await sync.disconnect();
      crypto.lock();
      store.close();
    }
  });
}
