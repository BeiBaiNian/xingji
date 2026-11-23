import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:path/path.dart' as p;
import 'package:timezone/data/latest.dart' as timezone_data;

import 'core/app_controller.dart';
import 'core/local_store.dart';
import 'core/vault_crypto.dart';
import 'platform/device_services.dart';
import 'platform/background_sync.dart';
import 'ui/mobile_workspace.dart';
import 'ui/onboarding.dart';
import 'ui/theme.dart';
import 'ui/workspace.dart';

Future<void> main(List<String> arguments) async {
  await launchXingJi(arguments);
}

@pragma('vm:entry-point')
Future<void> backgroundSync() => runBackgroundSync();

Future<AppController?> launchXingJi(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  timezone_data.initializeTimeZones();
  final profile = arguments
      .where((a) => a.startsWith('--data-dir='))
      .firstOrNull;
  try {
    final directory = profile == null
        ? await DeviceServices.dataDirectory()
        : profile.substring('--data-dir='.length);
    await Directory(directory).create(recursive: true);
    final store = LocalStore(p.join(directory, 'vault.sqlite3'));
    final crypto = await VaultCrypto.initialize();
    final app = AppController(store, crypto, directory);
    runApp(XingJiApp(app: app));
    await app.initialize();
    if (arguments.contains('--background')) await app.desktop.hide();
    return app;
  } catch (_) {
    runApp(
      MaterialApp(
        theme: xingjiTheme(),
        home: const Scaffold(
          body: Center(
            child: Padding(
              padding: EdgeInsets.all(40),
              child: SelectableText(
                '星记暂时无法启动。\n请检查资料目录的读写权限，并确认程序文件和运行库完整。\n原有资料未被删除。',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      ),
    );
    return null;
  }
}

class XingJiApp extends StatelessWidget {
  const XingJiApp({super.key, required this.app});
  final AppController app;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: app,
    builder: (context, _) => MaterialApp(
      title: '星记',
      debugShowCheckedModeBanner: false,
      theme: xingjiTheme(),
      darkTheme: xingjiTheme(dark: true),
      themeMode: app.darkMode ? ThemeMode.dark : ThemeMode.light,
      themeAnimationDuration: const Duration(milliseconds: 160),
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: AnimatedBuilder(
        animation: app,
        builder: (context, _) {
          final unlocked = app.unlocked && app.recoveryCode == null;
          return AnimatedSwitcher(
            duration: const Duration(milliseconds: 160),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeOut,
            child: KeyedSubtree(
              key: ValueKey(unlocked),
              child: unlocked
                  ? DeviceServices.mobile
                        ? MobileWorkspace(app: app)
                        : Workspace(app: app)
                  : VaultGate(app: app),
            ),
          );
        },
      ),
    ),
  );
}
