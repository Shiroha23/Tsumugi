import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/network/source_http_client.dart';
import 'package:tsumugi/shared/image/image_cache.dart';
import 'package:tsumugi/shared/image/source_image_loader.dart';
import 'package:tsumugi/sources/model/content.dart';
import 'package:tsumugi/sources/source.dart';

import '../../core/network/mock_support.dart';

const _page1 = 'http://img.example.com/pages/1.png';
const _page2 = 'http://img.example.com/pages/2.png';

void main() {
  late MockServer server;
  late Directory tmp;
  final clients = <SourceHttpClient>[];

  setUpAll(() async => server = await MockServer.start());
  tearDownAll(() => server.close());

  setUp(() async {
    server.requests.clear();
    tmp = await Directory.systemTemp.createTemp('tsumugi_img_');
  });

  tearDown(() async {
    for (final c in clients) {
      c.close();
    }
    clients.clear();
    await tmp.delete(recursive: true);
  });

  /// 每个 sourceId 一个独立客户端（与真实的按源客户端一致）。
  SourceImageLoader loaderWith({
    DiskImageCache? disk,
    Map<String, String> defaultHeaders = const {},
    Duration? timeout,
    int retries = 1,
  }) {
    final bySource = <String, SourceHttpClient>{};
    return SourceImageLoader(
      httpClientFor: (id) => bySource.putIfAbsent(id, () {
        final c = mockClient(server, sourceId: id, headers: defaultHeaders);
        clients.add(c);
        return c;
      }),
      diskCache: disk,
      timeout: timeout,
      retries: retries,
      retryDelay: const Duration(milliseconds: 10),
    );
  }

  bool isPng(Uint8List b) =>
      b.length > 8 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4e;

  group('SourceImageLoader', () {
    test('passes ImageRef headers and source default headers', () async {
      final loader = loaderWith(defaultHeaders: {'User-Agent': 'TsumugiTest'});
      final bytes = await loader.load(
        'com.example.comic',
        const ImageRef(
          url: _page1,
          headers: {'Referer': 'http://comic.example.com/book/1'},
        ),
      );
      expect(isPng(bytes), isTrue);
      final req = server.requests.single;
      expect(req.host, 'img.example.com');
      expect(req.path, '/pages/1.png');
      expect(req.headers['referer'], 'http://comic.example.com/book/1');
      expect(req.headers['user-agent'], 'TsumugiTest');
    });

    test('memory cache hit does not hit the network', () async {
      final loader = loaderWith();
      const ref = ImageRef(url: _page1);
      await loader.load('com.example.comic', ref);
      final progress = <ImageLoadStage>[];
      final again = await loader.load(
        'com.example.comic',
        ref,
        onProgress: (p) => progress.add(p.stage),
      );
      expect(isPng(again), isTrue);
      expect(server.hits('/pages/1.png'), 1);
      expect(progress, [ImageLoadStage.done]);
    });

    test('concurrent loads of the same image share one download', () async {
      final loader = loaderWith();
      const ref = ImageRef(url: _page1);
      await Future.wait([
        loader.load('com.example.comic', ref),
        loader.load('com.example.comic', ref),
        loader.load('com.example.comic', ref),
      ]);
      expect(server.hits('/pages/1.png'), 1);
    });

    test('reports downloading then done', () async {
      final loader = loaderWith();
      final stages = <ImageLoadStage>[];
      final last = <ImageLoadProgress>[];
      await loader.load(
        'com.example.comic',
        const ImageRef(url: _page2),
        onProgress: (p) {
          stages.add(p.stage);
          last.add(p);
        },
      );
      expect(stages, contains(ImageLoadStage.downloading));
      expect(stages.last, ImageLoadStage.done);
      expect(last.last.fraction, 1.0);
    });

    test('cache key includes sourceId', () async {
      final loader = loaderWith();
      const ref = ImageRef(url: _page1);
      await loader.load('com.example.a', ref);
      await loader.load('com.example.b', ref);
      expect(server.hits('/pages/1.png'), 2);
      expect(
        const ImageCacheKey('a', _page1).digest,
        isNot(const ImageCacheKey('b', _page1).digest),
      );
    });

    test('disk cache survives a new loader (memory cleared)', () async {
      final disk = FileDiskImageCache(() async => tmp);
      await loaderWith(disk: disk)
          .load('com.example.comic', const ImageRef(url: _page1));
      // 等待后台写盘。
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(await disk.sizeBytes(), greaterThan(0));

      final fresh = loaderWith(disk: FileDiskImageCache(() async => tmp));
      final bytes = await fresh.load(
        'com.example.comic',
        const ImageRef(url: _page1),
      );
      expect(isPng(bytes), isTrue);
      expect(server.hits('/pages/1.png'), 1);
    });

    test('evict removes memory and disk entries', () async {
      final disk = FileDiskImageCache(() async => tmp);
      final loader = loaderWith(disk: disk);
      const ref = ImageRef(url: _page1);
      await loader.load('com.example.comic', ref);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await loader.evict('com.example.comic', _page1);
      expect(await disk.sizeBytes(), 0);
      await loader.load('com.example.comic', ref);
      expect(server.hits('/pages/1.png'), 2);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });

    test('host outside the allowlist is rejected without a request', () async {
      final loader = loaderWith();
      await expectLater(
        loader.load(
          'com.example.comic',
          const ImageRef(url: 'http://outside.example.net/pages/1.png'),
        ),
        throwsA(
          isA<SourceException>().having(
            (e) => e.code,
            'code',
            SourceErrorCode.hostNotAllowed,
          ),
        ),
      );
      expect(server.requests, isEmpty);
    });

    test('HTTP errors surface as E_HTTP with status', () async {
      final loader = loaderWith();
      await expectLater(
        loader.load(
          'com.example.comic',
          const ImageRef(url: 'http://img.example.com/status/404'),
        ),
        throwsA(
          isA<SourceException>()
              .having((e) => e.code, 'code', SourceErrorCode.http)
              .having((e) => e.status, 'status', 404),
        ),
      );
      // 失败的结果不缓存：再次加载会重新请求。
      await expectLater(
        loader.load(
          'com.example.comic',
          const ImageRef(url: 'http://img.example.com/status/404'),
        ),
        throwsA(isA<SourceException>()),
      );
      expect(server.hits('/status/404'), 2);
    });

    test('timeouts are retried, then reported as E_NETWORK', () async {
      final loader = loaderWith(
        timeout: const Duration(milliseconds: 100),
        retries: 1,
      );
      await expectLater(
        loader.load(
          'com.example.comic',
          const ImageRef(url: 'http://img.example.com/slow?ms=400'),
        ),
        throwsA(
          isA<SourceException>().having(
            (e) => e.code,
            'code',
            SourceErrorCode.network,
          ),
        ),
      );
      expect(server.hits('/slow'), 2);
    });

    test('limits concurrent downloads', () async {
      var active = 0;
      var peak = 0;
      final loader = SourceImageLoader(
        maxConcurrent: 2,
        httpClientFor: (_) => _CountingClient(
          onStart: () => peak = (++active) > peak ? active : peak,
          onEnd: () => active--,
        ),
      );
      await Future.wait([
        for (var i = 0; i < 6; i++)
          loader.load('s', ImageRef(url: 'http://img.example.com/$i.png')),
      ]);
      expect(peak, 2);
    });
  });

  group('MemoryImageCache', () {
    test('evicts least recently used entries by bytes', () {
      final cache = MemoryImageCache(maxBytes: 30, maxEntryBytes: 30);
      Uint8List b(int n) => Uint8List(n);
      const a = ImageCacheKey('s', 'a'), bb = ImageCacheKey('s', 'b');
      const c = ImageCacheKey('s', 'c');
      cache.put(a, b(10));
      cache.put(bb, b(10));
      cache.get(a); // a 变为最近使用
      cache.put(c, b(15)); // 超出 → 淘汰 b
      expect(cache.get(bb), isNull);
      expect(cache.get(a), isNotNull);
      expect(cache.get(c), isNotNull);
      expect(cache.sizeBytes, 25);
    });

    test('skips entries larger than the per-entry limit', () {
      final cache = MemoryImageCache(maxBytes: 100);
      cache.put(const ImageCacheKey('s', 'big'), Uint8List(30));
      expect(cache.length, 0);
    });
  });

  group('FileDiskImageCache', () {
    test('LRU eviction keeps the total under maxBytes', () async {
      var now = DateTime(2026);
      final cache = FileDiskImageCache(
        () async => tmp,
        maxBytes: 25,
        clock: () => now = now.add(const Duration(seconds: 1)),
      );
      const a = ImageCacheKey('s', 'a'), b = ImageCacheKey('s', 'b');
      const c = ImageCacheKey('s', 'c');
      await cache.put(a, Uint8List(10));
      await cache.put(b, Uint8List(10));
      expect(await cache.get(a), isNotNull); // a 最近使用
      await cache.put(c, Uint8List(10));
      expect(await cache.get(b), isNull);
      expect(await cache.get(a), hasLength(10));
      expect(await cache.get(c), hasLength(10));
      expect(await cache.sizeBytes(), 20);
      expect(
        tmp.listSync().whereType<File>().map((f) => f.path).toSet(),
        hasLength(2),
      );
    });

    test('rebuilds its index from disk and trims to the limit', () async {
      final first = FileDiskImageCache(() async => tmp);
      for (final k in ['a', 'b', 'c']) {
        await first.put(ImageCacheKey('s', k), Uint8List(10));
      }
      File('${tmp.path}/leftover.123.tmp').writeAsBytesSync([1]);
      final second = FileDiskImageCache(() async => tmp, maxBytes: 20);
      expect(await second.sizeBytes(), 20);
      expect(File('${tmp.path}/leftover.123.tmp').existsSync(), isFalse);
    });

    test('clear removes everything', () async {
      final cache = FileDiskImageCache(() async => tmp);
      await cache.put(const ImageCacheKey('s', 'a'), Uint8List(5));
      await cache.clear();
      expect(await cache.sizeBytes(), 0);
      expect(tmp.listSync(), isEmpty);
    });
  });
}

/// 只统计并发数的假客户端。
class _CountingClient implements SourceHttpClient {
  _CountingClient({required this.onStart, required this.onEnd});

  final void Function() onStart;
  final void Function() onEnd;

  @override
  Future<NetResponse> request(NetRequest request) async {
    onStart();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    onEnd();
    return NetResponse(
      status: 200,
      url: Uri.parse(request.url),
      headersAll: const {},
      bytes: Uint8List.fromList([1, 2, 3]),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
