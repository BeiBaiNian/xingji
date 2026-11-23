// Explicit isolated encrypted fixture for the emulator's release upgrade check.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:xingji/core/local_store.dart';
import 'package:xingji/core/models.dart';
import 'package:xingji/core/vault_crypto.dart';

void main() {
  test('isolated Android upgrade fixture creation or decryption', () async {
    const location = String.fromEnvironment('XINGJI_UPGRADE_FIXTURE');
    const verify = bool.fromEnvironment('XINGJI_UPGRADE_VERIFY');
    final roots = [
      p.join(Directory.current.path, '.test-data'),
      p.join(Directory.current.parent.path, '.test-data'),
    ];
    if (location.isEmpty ||
        !roots.any((root) => p.isWithin(root, p.normalize(location)))) {
      throw StateError('Explicit fixture under .test-data required');
    }
    final file = File(location);
    if (verify != file.existsSync()) {
      throw StateError(
        'Creation never overwrites; verification requires an existing fixture',
      );
    }
    file.parent.createSync(recursive: true);
    final crypto = await VaultCrypto.initialize();
    final store = LocalStore(location);
    try {
      const password = 'Synthetic-Android-upgrade-only-2026';
      if (!verify) {
        final created = await crypto.create(password);
        store.setMeta('envelope', jsonEncode(created.envelope));
        store.setMeta('alarm_reminders', 'true');
        store.saveLocal(
          crypto.encrypt(Memo(title: '升级保留虚构事项', body: 'UPGRADE_FIXTURE_ONLY')),
        );
        store.saveLocal(crypto.encrypt(Memo(title: '升级保留虚构归档').complete()));
      } else {
        await crypto.unlock(store.envelope!, password);
        final memos = store.all().map((r) => crypto.decrypt(r.packet)).toList();
        expect(memos, hasLength(2));
        expect(memos.singleWhere((m) => !m.done).title, '升级保留虚构事项');
        expect(memos.singleWhere((m) => !m.done).body, 'UPGRADE_FIXTURE_ONLY');
        expect(memos.singleWhere((m) => m.done).title, '升级保留虚构归档');
      }
    } finally {
      crypto.lock();
      store.close();
    }
  });
}
