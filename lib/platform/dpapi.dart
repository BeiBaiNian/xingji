import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

final class _DataBlob extends Struct {
  @Uint32()
  external int length;
  external Pointer<Uint8> data;
}

typedef _ProtectNative = Int32 Function(
  Pointer<_DataBlob>,
  Pointer<Utf16>,
  Pointer<_DataBlob>,
  Pointer<Void>,
  Pointer<Void>,
  Uint32,
  Pointer<_DataBlob>,
);
typedef _Protect = int Function(
  Pointer<_DataBlob>,
  Pointer<Utf16>,
  Pointer<_DataBlob>,
  Pointer<Void>,
  Pointer<Void>,
  int,
  Pointer<_DataBlob>,
);
typedef _UnprotectNative = Int32 Function(
  Pointer<_DataBlob>,
  Pointer<Pointer<Utf16>>,
  Pointer<_DataBlob>,
  Pointer<Void>,
  Pointer<Void>,
  Uint32,
  Pointer<_DataBlob>,
);
typedef _Unprotect = int Function(
  Pointer<_DataBlob>,
  Pointer<Pointer<Utf16>>,
  Pointer<_DataBlob>,
  Pointer<Void>,
  Pointer<Void>,
  int,
  Pointer<_DataBlob>,
);

/// Current-user DPAPI. No password or raw vault key is written to disk.
class Dpapi {
  static final _crypt = DynamicLibrary.open('crypt32.dll');
  static final _protect = _crypt.lookupFunction<_ProtectNative, _Protect>(
    'CryptProtectData',
  );
  static final _unprotect = _crypt.lookupFunction<_UnprotectNative, _Unprotect>(
    'CryptUnprotectData',
  );
  static final _free = DynamicLibrary.open('kernel32.dll')
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>),
        Pointer<Void> Function(Pointer<Void>)
      >('LocalFree');

  static Uint8List protect(Uint8List bytes) => _transform(bytes, true);
  static Uint8List unprotect(Uint8List bytes) => _transform(bytes, false);

  static Uint8List _transform(Uint8List bytes, bool protect) {
    return using((arena) {
      final input = arena<_DataBlob>();
      input.ref.length = bytes.length;
      input.ref.data = arena<Uint8>(bytes.length);
      input.ref.data.asTypedList(bytes.length).setAll(0, bytes);
      final output = arena<_DataBlob>();
      try {
        final ok = protect
            ? _protect(input, nullptr, nullptr, nullptr, nullptr, 1, output)
            : _unprotect(input, nullptr, nullptr, nullptr, nullptr, 1, output);
        if (ok == 0) throw StateError('Windows 无法读取此设备的受保护凭据，请重新输入');
        try {
          return Uint8List.fromList(
            output.ref.data.asTypedList(output.ref.length),
          );
        } finally {
          output.ref.data
              .asTypedList(output.ref.length)
              .fillRange(0, output.ref.length, 0);
          _free(output.ref.data.cast<Void>());
        }
      } finally {
        input.ref.data.asTypedList(bytes.length).fillRange(0, bytes.length, 0);
      }
    });
  }
}
