import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:timezone/data/latest.dart' as timezone_data;

import '../core/local_store.dart';
import '../core/models.dart';
import '../core/sync_engine.dart';
import '../core/vault_crypto.dart';
import 'desktop_service.dart';
import 'device_services.dart';

/// A short-lived Android JobScheduler engine. No widgets, plaintext logs or
/// persistent service; manual lock and forgotten credentials disable it.
Future<void> runBackgroundSync() async {
  WidgetsFlutterBinding.ensureInitialized();
  timezone_data.initializeTimeZones();
  LocalStore? store;
  VaultCrypto? crypto;
  SyncEngine? sync;
  var success = false;
  try {
    final directory = await DeviceServices.dataDirectory();
    store = LocalStore(p.join(directory, 'vault.sqlite3'));
    final key = store.getMeta('trusted_key');
    final connection = store.getMeta('connection');
    if (store.envelope == null ||
        key == null ||
        connection == null ||
        store.getMeta('background_locked') == 'true' ||
        store.getMeta('background_sync') == 'false') {
      return;
    }
    crypto = await VaultCrypto.initialize();
    final raw = await DeviceServices.unprotect(base64Decode(key));
    try {
      crypto.unlockTrusted(store.envelope!['vault_id'] as String, raw);
      crypto.verifyEnvelope(store.envelope!);
    } finally {
      raw.fillRange(0, raw.length, 0);
    }
    final configBytes = await DeviceServices.unprotect(
      base64Decode(connection),
    );
    late ConnectionConfig config;
    try {
      config = ConnectionConfig.fromJson(
        jsonDecode(utf8.decode(configBytes)) as Json,
      );
    } finally {
      configBytes.fillRange(0, configBytes.length, 0);
    }
    sync = SyncEngine(store, crypto, onChanged: () {}, onState: () {});
    await sync.configure(config, autoStart: false);
    await sync.sync();
    final reminders = DesktopService(store, () {});
    await reminders.initialize();
    await reminders.reconcile(
      [
        for (final record in store.all())
          (memo: crypto.decrypt(record.packet), packet: record.packet),
      ],
      enabled: store.getMeta('notifications') != 'false',
      showTitles: store.getMeta('show_titles') == 'true',
      quiet: store.getMeta('quiet') == 'true',
      force: true,
    );
    success = !sync.hasError && sync.lastSuccess != null;
    store.setMeta('background_last_result', success ? 'success' : 'retry');
    if (success) {
      store.setMeta(
        'background_last_success',
        DateTime.now().toIso8601String(),
      );
    }
  } catch (_) {
    // Background failure leaves durable queued operations intact.
  } finally {
    await sync?.disconnect();
    crypto?.lock();
    store?.close();
    await DeviceServices.channel.invokeMethod('backgroundFinished', {
      'success': success,
    });
  }
}
