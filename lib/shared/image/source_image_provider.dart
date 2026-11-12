import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../../sources/model/content.dart';
import 'source_image_loader.dart';

/// 经 [SourceImageLoader] 加载源图片的 [ImageProvider]：可直接用于 `Image(image: ...)`、
/// `DecorationImage`、`precacheImage` 等。
///
/// 相等性只看 `sourceId` + `url` + `loader`（与磁盘缓存键一致），因此同一张图在 Flutter
/// 的解码缓存里只有一份。下载过程中会发出 [ImageChunkEvent]（总字节数未知时 `expectedTotalBytes` 为 null）。
@immutable
class SourceImageProvider extends ImageProvider<SourceImageProvider> {
  const SourceImageProvider({
    required this.sourceId,
    required this.ref,
    required this.loader,
    this.scale = 1.0,
  });

  final String sourceId;
  final ImageRef ref;
  final SourceImageLoader loader;
  final double scale;

  @override
  Future<SourceImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    SourceImageProvider key,
    ImageDecoderCallback decode,
  ) {
    final chunks = StreamController<ImageChunkEvent>();
    return MultiFrameImageStreamCompleter(
      codec: _load(key, decode, chunks),
      chunkEvents: chunks.stream,
      scale: key.scale,
      debugLabel: key.ref.url,
      informationCollector: () => [
        DiagnosticsProperty<String>('Source', key.sourceId),
        DiagnosticsProperty<String>('URL', key.ref.url),
      ],
    );
  }

  Future<ui.Codec> _load(
    SourceImageProvider key,
    ImageDecoderCallback decode,
    StreamController<ImageChunkEvent> chunks,
  ) async {
    try {
      final bytes = await key.loader.load(
        key.sourceId,
        key.ref,
        onProgress: (p) {
          if (p.stage == ImageLoadStage.downloading && !chunks.isClosed) {
            chunks.add(
              ImageChunkEvent(
                cumulativeBytesLoaded: p.receivedBytes ?? 0,
                expectedTotalBytes: p.totalBytes,
              ),
            );
          }
        },
      );
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      try {
        return await decode(buffer);
      } catch (_) {
        // 字节不是可解码的图片（例如站点返回了错误页）：不要让它留在缓存里。
        await key.loader.evict(key.sourceId, key.ref.url);
        rethrow;
      }
    } catch (_) {
      // 与 NetworkImage 一致：失败的条目移出解码缓存，之后可重试。
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key));
      rethrow;
    } finally {
      unawaited(chunks.close());
    }
  }

  @override
  bool operator ==(Object other) =>
      other is SourceImageProvider &&
      other.sourceId == sourceId &&
      other.ref.url == ref.url &&
      identical(other.loader, loader) &&
      other.scale == scale;

  @override
  int get hashCode => Object.hash(sourceId, ref.url, loader, scale);

  @override
  String toString() =>
      '${objectRuntimeType(this, 'SourceImageProvider')}("$sourceId", "${ref.url}", scale: $scale)';
}
