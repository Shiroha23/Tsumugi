import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show SynchronousFuture;

import '../../core/network/network_exception.dart';
import '../../core/network/source_http_client.dart';
import '../../sources/model/content.dart';
import '../../sources/network_error_mapping.dart';
import '../../sources/source.dart';
import 'image_cache.dart';

/// 由 sourceId 取得该源的 HTTP 客户端（遵守该源的白名单、限速、默认 headers 与 Cookie 域）。
typedef ImageHttpClientResolver = FutureOr<SourceHttpClient> Function(
  String sourceId,
);

/// 图片加载进度。目前网络层只在响应完整读取后返回，[receivedBytes] / [totalBytes]
/// 在下载过程中为 null（不确定进度），完成时为最终字节数。
final class ImageLoadProgress {
  const ImageLoadProgress(this.stage, {this.receivedBytes, this.totalBytes});

  final ImageLoadStage stage;
  final int? receivedBytes;
  final int? totalBytes;

  /// 0..1；未知时为 null。
  double? get fraction => switch ((receivedBytes, totalBytes)) {
    (final r?, final t?) when t > 0 => (r / t).clamp(0.0, 1.0),
    _ => null,
  };
}

enum ImageLoadStage {
  /// 等待并发名额 / 限速。
  queued,

  /// 正在下载。
  downloading,

  /// 已取得字节（来自缓存或网络）。
  done,
}

/// 统一的图片加载器：内存缓存 → 磁盘缓存 → 该源的网络层。
///
/// - 白名单、限速、默认 headers、Cookie、连接错误 / 5xx 重试由 [SourceHttpClient] 负责；
///   本类额外对超时 / 连接失败做 [retries] 次重试（每次都重新经过网络层的检查与限速）。
/// - 同一 [ImageCacheKey] 的并发请求合并为一次下载。
/// - 全局最多 [maxConcurrent] 个下载同时进行，避免预加载挤占阅读中的图片。
/// - 失败抛出 [SourceException]（错误码见 docs/source-spec.md §6）。
class SourceImageLoader {
  SourceImageLoader({
    required this.httpClientFor,
    MemoryImageCache? memoryCache,
    DiskImageCache? diskCache,
    this.maxConcurrent = 6,
    this.retries = 1,
    this.retryDelay = const Duration(milliseconds: 500),
    this.timeout,
  }) : memoryCache = memoryCache ?? MemoryImageCache(),
       diskCache = diskCache ?? const NoDiskImageCache();

  final ImageHttpClientResolver httpClientFor;
  final MemoryImageCache memoryCache;
  final DiskImageCache diskCache;
  final int maxConcurrent;
  final int retries;
  final Duration retryDelay;

  /// 覆盖源的单次请求超时（图片通常比页面大）。null 表示使用源配置。
  final Duration? timeout;

  final _inFlight = <ImageCacheKey, _Pending>{};
  final _waiting = Queue<Completer<void>>();
  int _running = 0;

  /// 加载 [ref] 的字节。[onProgress] 可能在调用返回前被同步调用。
  Future<Uint8List> load(
    String sourceId,
    ImageRef ref, {
    void Function(ImageLoadProgress progress)? onProgress,
  }) {
    final key = ImageCacheKey(sourceId, ref.url);
    final hit = memoryCache.get(key);
    if (hit != null) {
      onProgress?.call(
        ImageLoadProgress(
          ImageLoadStage.done,
          receivedBytes: hit.length,
          totalBytes: hit.length,
        ),
      );
      return SynchronousFuture(hit);
    }
    final pending = _inFlight[key] ??= _start(key, ref);
    if (onProgress != null) {
      onProgress(pending.last);
      pending.listeners.add(onProgress);
    }
    return pending.future.whenComplete(() {
      if (onProgress != null) pending.listeners.remove(onProgress);
    });
  }

  /// 只预取到缓存，忽略错误。
  void prefetch(String sourceId, ImageRef ref) {
    load(sourceId, ref).then((_) {}, onError: (_) {});
  }

  final _pendingWrites = <Future<void>>{};

  void _trackWrite(Future<void> write) {
    final tracked = write.then<void>((_) {}, onError: (Object _) {});
    _pendingWrites.add(tracked);
    tracked.whenComplete(() => _pendingWrites.remove(tracked));
  }

  /// 等待已发起的后台磁盘写入完成（例如退出前或测试中）。
  Future<void> flushDiskWrites() => Future.wait(List.of(_pendingWrites));

  /// 删除某张图的缓存（例如字节无法解码时）。
  Future<void> evict(String sourceId, String url) {
    final key = ImageCacheKey(sourceId, url);
    memoryCache.remove(key);
    return diskCache.remove(key);
  }

  _Pending _start(ImageCacheKey key, ImageRef ref) {
    final pending = _Pending();
    pending.future = _fetch(
      key,
      ref,
      pending,
    ).whenComplete(() => _inFlight.remove(key));
    return pending;
  }

  Future<Uint8List> _fetch(
    ImageCacheKey key,
    ImageRef ref,
    _Pending pending,
  ) async {
    final cached = await diskCache.get(key);
    if (cached != null) {
      memoryCache.put(key, cached);
      pending.emit(_done(cached));
      return cached;
    }

    await _acquire();
    try {
      final client = await httpClientFor(key.sourceId);
      pending.emit(const ImageLoadProgress(ImageLoadStage.downloading));
      for (var attempt = 0; ; attempt++) {
        try {
          final res = await client.request(
            NetRequest(
              ref.url,
              headers: ref.headers ?? const {},
              throwOnHttpError: true,
              timeout: timeout,
            ),
          );
          if (res.bytes.isEmpty) {
            throw const SourceException(
              SourceErrorCode.parse,
              'empty image response',
            );
          }
          final bytes = res.bytes;
          memoryCache.put(key, bytes);
          // 磁盘写入不阻塞返回。
          _trackWrite(diskCache.put(key, bytes));
          pending.emit(_done(bytes));
          return bytes;
        } on NetworkException catch (e) {
          final transient =
              e.kind == NetworkErrorKind.timeout ||
              e.kind == NetworkErrorKind.connection;
          if (transient && attempt < retries) {
            await Future<void>.delayed(retryDelay * (attempt + 1));
            continue;
          }
          throw e.toSourceException();
        }
      }
    } finally {
      _release();
    }
  }

  static ImageLoadProgress _done(Uint8List b) => ImageLoadProgress(
    ImageLoadStage.done,
    receivedBytes: b.length,
    totalBytes: b.length,
  );

  Future<void> _acquire() async {
    if (_running < maxConcurrent) {
      _running++;
      return;
    }
    final c = Completer<void>();
    _waiting.add(c);
    await c.future; // 名额由 _release 直接转交
  }

  void _release() {
    if (_waiting.isNotEmpty) {
      _waiting.removeFirst().complete();
    } else {
      _running--;
    }
  }
}

class _Pending {
  late final Future<Uint8List> future;
  final listeners = <void Function(ImageLoadProgress)>[];
  ImageLoadProgress last = const ImageLoadProgress(ImageLoadStage.queued);

  void emit(ImageLoadProgress p) {
    last = p;
    for (final l in List.of(listeners)) {
      l(p);
    }
  }
}
