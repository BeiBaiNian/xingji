import 'dart:typed_data';

class ImageAttachment {
  const ImageAttachment(
    this.id,
    this.originId,
    this.width,
    this.height,
    this.byteLength,
  );

  final String id, originId;
  final int width, height, byteLength;
  static const mimeType = 'image/jpeg';
  static const maxPerMemo = 9;
  static const countLimitMessage = '每条备忘录最多添加 $maxPerMemo 张图片';
  static const maxInputBytes = 32 * 1024 * 1024;
  static const maxEdge = 2048;
  static const maxBytes = 8 * 1024 * 1024;
  static const maxVaultBytes = 500 * 1024 * 1024;
  static const chunkBytes = 256 * 1024;
  int get chunkCount => (byteLength + chunkBytes - 1) ~/ chunkBytes;

  void validate() {
    if (width < 1 ||
        height < 1 ||
        width > maxEdge ||
        height > maxEdge ||
        byteLength < 1 ||
        byteLength > maxBytes) {
      throw const FormatException('图片尺寸或大小超出限制');
    }
  }
}

typedef ImageChunk = ({Uint8List nonce, Uint8List ciphertext});
typedef MemoImageLink = ({String memoId, ImageAttachment image, Uint8List tag});
typedef RelinkImage = MemoImageLink Function(
  MemoImageLink source,
  String memoId,
);
typedef ProcessedImage = ({Uint8List jpeg, int width, int height});
