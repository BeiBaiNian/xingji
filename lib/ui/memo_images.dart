import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_controller.dart';
import '../core/image_attachment.dart';
import '../platform/device_services.dart';
import '../platform/image_processing.dart';

class MemoImages extends StatefulWidget {
  const MemoImages({
    super.key,
    required this.app,
    required this.memoId,
    this.onBusyChanged,
  });
  final AppController app;
  final String memoId;
  final ValueChanged<bool>? onBusyChanged;

  @override
  MemoImagesState createState() => MemoImagesState();
}

class MemoImagesState extends State<MemoImages> {
  bool busy = false;
  String? error;
  bool get editable => widget.onBusyChanged != null;

  bool current(String id) =>
      mounted &&
      widget.app.unlocked &&
      widget.memoId == id &&
      widget.app.selectedId == id;

  Future<void> pasteFromClipboard({VoidCallback? onEmpty}) =>
      _add(paste: true, onEmpty: onEmpty);

  Future<void> _add({required bool paste, VoidCallback? onEmpty}) async {
    final id = widget.memoId;
    if (busy || !editable || !current(id)) return;
    if (widget.app.store.imageLinks(id).length >= ImageAttachment.maxPerMemo) {
      setState(() => error = ImageAttachment.countLimitMessage);
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    widget.onBusyChanged?.call(true);
    try {
      final source = await (paste
          ? DeviceServices.pasteImage()
          : DeviceServices.pickImage());
      if (!current(id)) return;
      if (source == null) {
        if (paste) setState(() => error = '剪贴板中没有图片');
        onEmpty?.call();
        return;
      }
      final image = await processMemoImage(source);
      try {
        if (current(id)) widget.app.addImage(id, image);
      } finally {
        image.jpeg.fillRange(0, image.jpeg.length, 0);
      }
    } catch (e) {
      if (current(id)) {
        final message = switch (e) {
          FormatException() => e.message,
          PlatformException(code: 'image' || 'clipboard_image') => e.message,
          _ => null,
        };
        setState(() => error = message ?? '无法添加图片，请重试');
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
        widget.onBusyChanged?.call(false);
      }
    }
  }

  Future<void> remove(String imageId) async {
    final id = widget.memoId;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('从这条备忘录移除图片？'),
        content: const Text('移除后无法从修改历史找回这张图片。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('移除图片'),
          ),
        ],
      ),
    );
    if (confirmed != true || !current(id)) return;
    try {
      widget.app.removeImage(id, imageId);
      setState(() => error = null);
    } catch (e) {
      setState(() => error = e is FormatException ? e.message : '移除图片失败，请重试');
    }
  }

  Future<void> preview(ImageAttachment image) async {
    final app = widget.app;
    final id = widget.memoId;
    final navigator = Navigator.of(context);
    final route = DialogRoute<void>(
      context: context,
      builder: (context) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        child: SizedBox(
          width: 920,
          height: 680,
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: IconButton(
                  tooltip: '关闭预览',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ),
              Expanded(
                child: ClipRect(
                  child: InteractiveViewer(
                    maxScale: 6,
                    child: Center(
                      child: _AttachmentBitmap(
                        app: app,
                        memoId: id,
                        image: image,
                        fullSize: true,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    void checkAccess() {
      if (route.isActive &&
          (!app.unlocked ||
              !app.store.imageLinks(id).any((l) => l.image.id == image.id))) {
        navigator.removeRoute(route);
      }
    }

    app.addListener(checkAccess);
    try {
      await navigator.push(route);
    } finally {
      app.removeListener(checkAccess);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.app.unlocked) return const SizedBox.shrink();
    final links = widget.app.store.imageLinks(widget.memoId);
    if (!editable && links.isEmpty) return const SizedBox.shrink();
    final canAdd = !busy && links.length < ImageAttachment.maxPerMemo;
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '本机图片 ${links.length}/${ImageAttachment.maxPerMemo}',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              if (editable &&
                  Theme.of(context).platform == TargetPlatform.windows)
                const Text('复制图片后，在标题或正文按 Ctrl+V 添加')
              else if (editable) ...[
                TextButton.icon(
                  onPressed: canAdd ? () => _add(paste: false) : null,
                  icon: const Icon(
                    Icons.add_photo_alternate_outlined,
                    size: 18,
                  ),
                  label: const Text('选择图片'),
                ),
                TextButton.icon(
                  onPressed: canAdd ? pasteFromClipboard : null,
                  icon: const Icon(Icons.content_paste, size: 18),
                  label: const Text('粘贴图片'),
                ),
              ],
            ],
          ),
          if (editable)
            Text(
              '图片仅保存在此设备，未纳入同步、备份和修改历史。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          if (busy) const Text('正在添加图片…'),
          if (error != null)
            Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (links.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (var i = 0; i < links.length; i++)
                    SizedBox(
                      key: ValueKey(links[i].image.id),
                      width: 104,
                      height: 96,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Material(
                            color: Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(8),
                            clipBehavior: Clip.antiAlias,
                            child: InkWell(
                              onTap: () => preview(links[i].image),
                              child: Semantics(
                                label: '查看第 ${i + 1} 张图片',
                                button: true,
                                child: _AttachmentBitmap(
                                  app: widget.app,
                                  memoId: widget.memoId,
                                  image: links[i].image,
                                ),
                              ),
                            ),
                          ),
                          if (editable)
                            Align(
                              alignment: Alignment.topRight,
                              child: IconButton.filledTonal(
                                tooltip: '移除第 ${i + 1} 张图片',
                                visualDensity: VisualDensity.compact,
                                iconSize: 16,
                                onPressed: busy
                                    ? null
                                    : () => remove(links[i].image.id),
                                icon: const Icon(Icons.close),
                              ),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// Own the decoded frame so private images never enter Flutter's global ImageCache.
class _AttachmentBitmap extends StatefulWidget {
  const _AttachmentBitmap({
    required this.app,
    required this.memoId,
    required this.image,
    this.fullSize = false,
  });
  final AppController app;
  final String memoId;
  final ImageAttachment image;
  final bool fullSize;
  @override
  State<_AttachmentBitmap> createState() => _AttachmentBitmapState();
}

class _AttachmentBitmapState extends State<_AttachmentBitmap> {
  ui.Image? frame;
  bool failed = false;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    ui.Codec? codec;
    Uint8List? bytes;
    try {
      final image = widget.image;
      bytes = widget.app.readImage(widget.memoId, image.id);
      codec = await ui.instantiateImageCodec(
        bytes,
        allowUpscaling: false,
        targetWidth: !widget.fullSize && image.width >= image.height
            ? 192
            : null,
        targetHeight: !widget.fullSize && image.height > image.width
            ? 192
            : null,
      );
      final decoded = (await codec.getNextFrame()).image;
      if (!mounted || !widget.app.unlocked) {
        decoded.dispose();
      } else {
        setState(() => frame = decoded);
      }
    } catch (_) {
      if (mounted) setState(() => failed = true);
    } finally {
      codec?.dispose();
      bytes?.fillRange(0, bytes.length, 0);
    }
  }

  @override
  void dispose() {
    frame?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => failed
      ? const Center(child: Text('图片无法读取'))
      : RawImage(
          image: frame,
          fit: widget.fullSize ? BoxFit.contain : BoxFit.cover,
        );
}
