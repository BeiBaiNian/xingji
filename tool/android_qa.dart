// Development-only entry point for an isolated emulator. Release uses lib/main.dart.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:xingji/core/models.dart';
import 'package:xingji/core/sync_engine.dart';
import 'package:xingji/main.dart' as application;
import 'package:xingji/platform/desktop_service.dart';
import 'package:xingji/platform/device_services.dart';

@pragma('vm:entry-point')
Future<void> backgroundSync() => application.backgroundSync();

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

Future<void> main() async {
  final app = await application.launchXingJi([]);
  if (app == null) return;
  final output = File('${app.dataDirectory}/qa-result.json');
  if (app.store.getMeta('android_qa_complete') == 'true') return;
  try {
    const vault = String.fromEnvironment('QA_VAULT');
    check(vault.isNotEmpty, 'Explicit isolated fixture required');
    final raw = Uint8List.fromList(List.generate(32, (i) => i));
    final wrapped = await DeviceServices.protect(raw);
    final recovered = await DeviceServices.unprotect(wrapped);
    check(base64Encode(raw) == base64Encode(recovered), 'Keystore round trip');
    final damaged = Uint8List.fromList(wrapped)..[20] ^= 1;
    var rejected = false;
    try {
      await DeviceServices.unprotect(damaged);
    } on PlatformException {
      rejected = true;
    }
    check(rejected, 'Keystore tamper rejection');
    const config = ConnectionConfig(
      host: '127.0.0.1',
      port: 55473,
      database: 'postgres',
      username: 'test_device_a',
      tls: false,
    );
    if (!app.exists) {
      final remote = (await SyncEngine.remoteVaults(config))
          .singleWhere((v) => v['vault_id'] == vault);
      await app.join(config, remote, 'Android-QA-only-2026', true);
    }
    Future<void> sync() async {
      while (app.sync.running) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      await app.sync.sync();
      check(!app.sync.hasError, app.sync.status);
    }

    await sync();
    final pc = app.memos.singleWhere((m) => m.title == '电脑传来的备忘录');
    check(
      pc.body == 'QA_PC_CIPHERTEXT_ONLY' && pc.tags.single == '跨端验证',
      'Windows to Android decryption',
    );
    await app.save(pc.complete());
    final trash = app.memos.singleWhere((m) => m.title == 'QA_TRASH');
    await app.purge(trash);
    final reminder = Memo(
      title: '手机提醒验证',
      body: '离线提醒、通知操作与重启恢复验证。',
      dueAt: DateTime.now().add(const Duration(seconds: 90)),
      tags: ['手机测试'],
      priority: 2,
    );
    await app.save(reminder);
    await app.save(
      Memo(
        title: '整理今天的安排',
        body: '点击查看详情；更多属性在编辑页展开。',
        dueAt: DateTime.now().add(const Duration(hours: 2)),
        tags: ['日常'],
        priority: 1,
        checklist: [CheckItem(text: '回看已经完成的事项')],
      ),
    );
    await sync();
    check(app.store.pendingCount == 0, 'Durable queues acknowledged');
    final packets = app.store.all().map((r) => r.packet.toJson()).toList();
    check(
      !jsonEncode(packets).contains('QA_PC_CIPHERTEXT_ONLY'),
      'SQLite encrypted',
    );
    final backup = app.exportBackup();
    check(!backup.contains('QA_PC_CIPHERTEXT_ONLY'), 'Backup encrypted');
    final restored = app.crypto.decryptBackup(jsonDecode(backup) as Json);
    check((restored['records'] as List).isNotEmpty, 'Backup decrypts');
    await app.desktop.waitForPending();
    await app.schedule(force: true);
    final state = await DesktopService.channel.invokeMapMethod<String, dynamic>(
      'notificationState',
    );
    check(
      state?['allowed'] == true && state?['exact'] == true,
      'Android 8 notifications',
    );
    check((state?['scheduled'] as int) >= 2, 'Native alarms persisted');
    app.store.setMeta('android_qa_complete', 'true');
    app.select(null);
    await output.writeAsString(
      jsonEncode({
        'passed': true,
        'vault': vault,
        'reminder': reminder.id,
        'dueAt': reminder.dueAt!.toUtc().toIso8601String(),
        'keystore': true,
        'tamperRejected': true,
        'windowsToAndroid': true,
        'encryptedSQLite': true,
        'encryptedBackup': true,
        'nativeState': state,
      }),
    );
  } catch (e, stack) {
    await output.writeAsString(
      jsonEncode({'passed': false, 'error': '$e', 'stack': '$stack'}),
    );
  }
  debugPrint('XINGJI_QA_RESULT ${await output.readAsString()}');
}
