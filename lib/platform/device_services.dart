import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../core/image_attachment.dart';
import 'desktop_service.dart';
import 'dpapi.dart';
import 'image_processing.dart';

/// Platform-specific device protection. The vault's portable encryption stays
/// in VaultCrypto; these wrappers never leave the originating device.
class DeviceServices {
  static const channel = MethodChannel('xingji/device');
  static bool get mobile => Platform.isAndroid;
  static String get protection => mobile ? 'Android Keystore' : 'Windows DPAPI';

  static Future<String> dataDirectory() async => mobile
      ? (await channel.invokeMethod<String>('dataDirectory'))!
      : p.join(
          Platform.environment['LOCALAPPDATA'] ?? Directory.current.path,
          'XingJi',
        );

  static Future<Uint8List> protect(Uint8List bytes) async => mobile
      ? (await channel.invokeMethod<Uint8List>('protect', bytes))!
      : Dpapi.protect(bytes);

  static Future<Uint8List> unprotect(Uint8List bytes) async {
    if (!mobile) return Dpapi.unprotect(bytes);
    // Platform channel buffers may be read-only. Callers clear their working
    // copy after use; never let that cleanup turn a valid unlock into a failure.
    final decoded = (await channel.invokeMethod<Uint8List>(
      'unprotect',
      bytes,
    ))!;
    return Uint8List.fromList(decoded);
  }

  static Future<void> background(bool enabled) async {
    if (mobile) await channel.invokeMethod('background', {'enabled': enabled});
  }

  static Future<bool> acquireSync() async =>
      !mobile || (await channel.invokeMethod<bool>('acquireSync')) == true;
  static Future<void> releaseSync() async {
    if (mobile) await channel.invokeMethod('releaseSync');
  }

  static Future<String?> pickFile({required bool certificate}) async {
    if (mobile) {
      return channel.invokeMethod<String>('pickFile', {
        'certificate': certificate,
      });
    }
    return (await openFile(
      acceptedTypeGroups: [
        XTypeGroup(
          label: certificate ? '证书' : '星记加密备份',
          extensions: certificate ? ['pem', 'crt', 'cer'] : ['xingji'],
        ),
      ],
    ))?.path;
  }

  static Future<void> withBackupFile(Future<void> Function(String) read) async {
    final path = await pickFile(certificate: false);
    if (path == null) return;
    try {
      await read(path);
    } finally {
      if (mobile) await channel.invokeMethod<void>('releaseBackupImport', path);
    }
  }

  static Future<Uint8List?> pickImage() async {
    if (mobile) return channel.invokeMethod<Uint8List>('pickImage');
    final selected = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(
          label: '图片',
          extensions: ['png', 'jpg', 'jpeg', 'webp', 'bmp', 'gif'],
        ),
      ],
    );
    if (selected == null) return null;
    final file = await File(selected.path).open();
    try {
      final length = await file.length();
      if (length > ImageAttachment.maxInputBytes) {
        throw const FormatException('请选择 32 MiB 以内的图片');
      }
      return await file.read(length);
    } finally {
      await file.close();
    }
  }

  static Future<Uint8List?> pasteImage() async {
    if (mobile) return channel.invokeMethod<Uint8List>('pasteImage');
    final value = await DesktopService.channel.invokeMapMethod<String, dynamic>(
      'readClipboardImage',
    );
    if (value == null) return null;
    final bytes = value['bytes'] as Uint8List;
    return value['format'] == 'dib' ? bmpFromClipboardDib(bytes) : bytes;
  }

  static Future<bool> saveBackup(String name, Uint8List bytes) async {
    if (mobile) {
      return (await channel.invokeMethod<bool>('saveBackup', {
            'name': name,
            'bytes': bytes,
          })) ==
          true;
    }
    final location = await getSaveLocation(
      suggestedName: name,
      acceptedTypeGroups: [
        const XTypeGroup(label: '星记加密备份', extensions: ['xingji']),
      ],
    );
    if (location == null) return false;
    await XFile.fromData(
      bytes,
      mimeType: 'application/octet-stream',
    ).saveTo(location.path);
    return true;
  }
}
