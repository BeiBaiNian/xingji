// Development-only upgrade test. Never used by tool/build_android.ps1.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:xingji/core/app_controller.dart';
import 'package:xingji/core/models.dart';
import 'package:xingji/main.dart' as application;
import 'package:xingji/platform/desktop_service.dart';

@pragma('vm:entry-point')
Future<void> backgroundSync() => application.backgroundSync();

void check(bool value, String label) {
  if (!value) throw StateError(label);
}

Future<AppController> restart(AppController app) async {
  await app.flushEditor?.call();
  await app.sync.disconnect();
  await app.desktop.waitForPending();
  runApp(const SizedBox.shrink());
  await WidgetsBinding.instance.endOfFrame;
  app.dispose();
  app.store.close();
  return (await application.launchXingJi([]))!;
}

Future<void> main() async {
  var app = (await application.launchXingJi([]))!;
  if (app.store.getMeta('android_031_complete') == 'true') return;
  final result = <String, dynamic>{};
  try {
    const vault = String.fromEnvironment('QA_VAULT');
    check(
      app.store.envelope?['vault_id'] == vault && vault.isNotEmpty,
      'Isolated upgraded fixture required',
    );
    if (!app.unlocked) await app.unlock('Android-QA-only-2026', trust: true);
    final verified = app.store.getMeta('password_verified_at');
    check(app.trustPeriodValid, 'Fresh verification');
    app = await restart(app);
    check(app.unlocked, 'Trusted restart must not ask for password');
    check(
      app.store.getMeta('password_verified_at') == verified,
      'Restart must not renew verification',
    );
    result['trustedRestart'] = true;
    app.store.setMeta(
      'password_verified_at',
      DateTime.now()
          .subtract(const Duration(hours: 73))
          .toUtc()
          .toIso8601String(),
    );
    final expired = app.store.getMeta('password_verified_at');
    app = await restart(app);
    check(!app.unlocked, 'Expired verification must lock the UI');
    try {
      await app.unlock('wrong-test-password', trust: true);
    } catch (_) {}
    check(
      !app.unlocked && app.store.getMeta('password_verified_at') == expired,
      'Wrong password cannot renew trust',
    );
    result['expiryAndWrongPassword'] = true;
    await app.unlock('Android-QA-only-2026', trust: true);
    await app.lock();
    app = await restart(app);
    check(!app.unlocked, 'Explicit lock must override the trust period');
    await app.unlock('Android-QA-only-2026', trust: true);
    result['manualLock'] = true;
    await app.setting('alarm_reminders', true);
    final memo = Memo(
      title: '新版闹铃验证',
      dueAt: DateTime.now().add(const Duration(seconds: 45)),
      priority: 3,
    );
    await app.save(memo);
    app.select(null);
    await app.desktop.waitForPending();
    await app.schedule(force: true);
    result['alarm'] = memo.id;
    result['dueAt'] = memo.dueAt!.toUtc().toIso8601String();
    result['native'] = await DesktopService.channel
        .invokeMapMethod<String, dynamic>('notificationState');
    result['passed'] = true;
    app.store.setMeta('android_031_complete', 'true');
  } catch (e, stack) {
    result['passed'] = false;
    result['error'] = '$e';
    result['stack'] = '$stack';
  }
  await File('${app.dataDirectory}/qa-031-result.json')
      .writeAsString(jsonEncode(result));
  debugPrint('XINGJI_031_QA_RESULT ${jsonEncode(result)}');
}
