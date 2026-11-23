import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../core/image_attachment.dart';

Uint8List _encodeJpeg(({ByteData rgba, int width, int height}) frame) {
  final pixels = img.Image.fromBytes(
    width: frame.width,
    height: frame.height,
    bytes: frame.rgba.buffer,
    bytesOffset: frame.rgba.offsetInBytes,
    order: img.ChannelOrder.rgba,
    backgroundColor: img.ColorRgb8(255, 255, 255),
  );
  return img.encodeJpg(pixels, quality: 80);
}

Future<ProcessedImage> processMemoImage(Uint8List bytes) async {
  if (bytes.isEmpty || bytes.length > ImageAttachment.maxInputBytes) {
    throw const FormatException('请选择 32 MiB 以内的图片');
  }
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  late final ({ByteData rgba, int width, int height}) pixels;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? frame;
  try {
    // Flutter's codec reports oriented dimensions and applies EXIF orientation
    // while decoding. Passing target dimensions lets JPEG decoders subsample.
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final w = descriptor.width, h = descriptor.height;
    final jpeg =
        bytes.length >= 3 &&
        bytes[0] == 0xff &&
        bytes[1] == 0xd8 &&
        bytes[2] == 0xff;
    if (w < 1 || h < 1 || w * h > (jpeg ? 64000000 : 16000000)) {
      throw const FormatException('图片像素过多，请先缩小后添加');
    }
    final scale = math.min(1.0, ImageAttachment.maxEdge / math.max(w, h));
    codec = await descriptor.instantiateCodec(
      targetWidth: math.max(1, (w * scale).round()),
      targetHeight: math.max(1, (h * scale).round()),
    );
    frame = (await codec.getNextFrame()).image;
    final rgba = await frame.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    if (rgba == null) throw const FormatException('图片无法解码');
    pixels = (rgba: rgba, width: frame.width, height: frame.height);
  } on FormatException {
    rethrow;
  } on Exception {
    throw const FormatException('无法读取这张图片，文件可能损坏或格式不受支持');
  } finally {
    frame?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
  // Release the decoder and its native buffers before encoding. Only the
  // first frame's oriented pixels cross into the JPEG, including no EXIF.
  final output = await compute(_encodeJpeg, pixels);
  if (output.length > ImageAttachment.maxBytes) {
    throw const FormatException('处理后的图片超过 8 MiB');
  }
  return (jpeg: output, width: pixels.width, height: pixels.height);
}

/// Windows clipboard bitmaps are packed DIBs without the BMP file header.
Uint8List bmpFromClipboardDib(Uint8List dib) {
  const invalid = FormatException('剪贴板位图格式不受支持');
  if (dib.length < 40 || dib.length + 14 > ImageAttachment.maxInputBytes) {
    throw invalid;
  }
  final header = ByteData.sublistView(dib);
  final size = header.getUint32(0, Endian.little);
  if (![40, 52, 56, 108, 124].contains(size) || size > dib.length) {
    throw invalid;
  }
  final width = header.getInt32(4, Endian.little);
  final height = header.getInt32(8, Endian.little).abs();
  final planes = header.getUint16(12, Endian.little);
  final bits = header.getUint16(14, Endian.little);
  final compression = header.getUint32(16, Endian.little);
  if (width < 1 ||
      height < 1 ||
      width * height > 16000000 ||
      planes != 1 ||
      ![1, 4, 8, 16, 24, 32].contains(bits) ||
      ![0, 3, 6].contains(compression)) {
    throw invalid;
  }
  var colors = header.getUint32(32, Endian.little);
  if (colors == 0 && bits <= 8) colors = 1 << bits;
  final masks = size == 40 && compression != 0
      ? (compression == 6 ? 16 : 12)
      : 0;
  var offset = size + masks + colors * 4;
  if (size == 124 && header.getUint32(112, Endian.little) == offset) {
    offset += header.getUint32(
      116,
      Endian.little,
    ); // embedded profile precedes pixels
  }
  final stride = ((width * bits + 31) ~/ 32) * 4;
  if (offset + stride * height > dib.length) throw invalid;
  final bmp = Uint8List(dib.length + 14);
  final file = ByteData.sublistView(bmp);
  file.setUint16(0, 0x4d42, Endian.little);
  file.setUint32(2, bmp.length, Endian.little);
  file.setUint32(10, 14 + offset, Endian.little);
  bmp.setRange(14, bmp.length, dib);
  return bmp;
}
