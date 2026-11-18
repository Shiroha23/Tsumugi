import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/network/source_http_client.dart';
import 'package:tsumugi/features/comic/reader/reader_page_image.dart';
import 'package:tsumugi/shared/image/image_providers.dart';
import 'package:tsumugi/shared/image/source_image.dart';
import 'package:tsumugi/shared/image/source_image_loader.dart';
import 'package:tsumugi/shared/image/source_image_provider.dart';
import 'package:tsumugi/sources/model/content.dart';

import 'image_fakes.dart';

/// 由测试逐步推进的图片客户端：[progress] 调用请求的进度回调，[finish] 返回字节。
class _SteppedImageClient implements SourceHttpClient {
  NetRequest? current;
  final _done = Completer<NetResponse>();

  void progress(int received, int? total) =>
      current!.onReceiveProgress?.call(received, total);

  void finish(Uint8List bytes) => _done.complete(
    NetResponse(
      status: 200,
      url: Uri.parse(current!.url),
      headersAll: const {
        'content-type': ['image/png'],
      },
      bytes: bytes,
    ),
  );

  @override
  Future<NetResponse> request(NetRequest request) {
    current = request;
    return _done.future;
  }

  @override
  Future<NetStreamResponse> openStream(
    NetRequest request, {
    RateLimitLane lane = RateLimitLane.source,
    void Function(bool waiting)? onRateLimitWait,
  }) => throw UnimplementedError();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _url = 'http://img.example.com/pages/1.png';
const _source = 'com.example.comic';

double? _indicatorValue(WidgetTester tester) => tester
    .widget<CircularProgressIndicator>(find.byType(CircularProgressIndicator))
    .value;

/// 进度事件经加载器 → chunk 流 → ImageStream 异步传到组件，多 pump 一帧再断言。
Future<void> _pumpChunk(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

/// 图片解码要在真实异步中进行：交替让出真实时间与 pump，直到没有进度指示器。
Future<void> _settleDecode(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    if (find.byType(CircularProgressIndicator).evaluate().isEmpty) return;
  }
}

void main() {
  late _SteppedImageClient client;
  late SourceImageLoader loader;

  setUp(() {
    client = _SteppedImageClient();
    loader = SourceImageLoader(httpClientFor: (_) => client);
  });

  tearDown(() {
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  });

  Future<void> pumpApp(WidgetTester tester, Widget child) => tester.pumpWidget(
    ProviderScope(
      overrides: [sourceImageLoaderProvider.overrideWithValue(loader)],
      child: MaterialApp(
        home: Center(child: SizedBox(width: 200, height: 300, child: child)),
      ),
    ),
  );

  group('ImageLoadingIndicator', () {
    testWidgets('有总长度时为确定进度，否则为不确定进度', (tester) async {
      Future<double?> valueFor(ImageChunkEvent? e) async {
        await tester.pumpWidget(
          MaterialApp(home: ImageLoadingIndicator(progress: e)),
        );
        return _indicatorValue(tester);
      }

      expect(await valueFor(null), isNull);
      expect(
        await valueFor(
          const ImageChunkEvent(
            cumulativeBytesLoaded: 30,
            expectedTotalBytes: null,
          ),
        ),
        isNull,
      );
      expect(
        await valueFor(
          const ImageChunkEvent(
            cumulativeBytesLoaded: 30,
            expectedTotalBytes: 120,
          ),
        ),
        0.25,
      );
      // 服务器多发了字节也不超过 1。
      expect(
        await valueFor(
          const ImageChunkEvent(
            cumulativeBytesLoaded: 200,
            expectedTotalBytes: 100,
          ),
        ),
        1.0,
      );
    });

    testWidgets('compact 为小尺寸', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Center(child: ImageLoadingIndicator(compact: true)),
        ),
      );
      expect(
        tester.getSize(find.byType(ImageLoadingIndicator)),
        const Size.square(18),
      );
    });
  });

  testWidgets('SourceImage：下载中显示确定进度，完成后显示图片', (tester) async {
    await pumpApp(
      tester,
      const SourceImage(
        sourceId: _source,
        image: ImageRef(url: _url),
      ),
    );
    await tester.pump();
    client.progress(0, 1000);
    await _pumpChunk(tester);
    expect(_indicatorValue(tester), 0.0);
    client.progress(400, 1000);
    await _pumpChunk(tester);
    expect(_indicatorValue(tester), closeTo(0.4, 1e-9));
    client.progress(1000, 1000);
    await _pumpChunk(tester);
    expect(_indicatorValue(tester), 1.0);

    client.finish(png1x1);
    await _settleDecode(tester);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('SourceImage：没有总长度时退回不确定进度', (tester) async {
    await pumpApp(
      tester,
      const SourceImage(
        sourceId: _source,
        image: ImageRef(url: _url),
      ),
    );
    await tester.pump();
    client.progress(0, null);
    client.progress(500, null);
    await _pumpChunk(tester);
    expect(_indicatorValue(tester), isNull);
    client.finish(png1x1);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
  });

  testWidgets('CoverImage：小尺寸确定进度', (tester) async {
    await pumpApp(
      tester,
      const CoverImage(sourceId: _source, url: _url, width: 90),
    );
    await tester.pump();
    client.progress(250, 1000);
    await _pumpChunk(tester);
    expect(_indicatorValue(tester), 0.25);
    expect(
      tester.getSize(find.byType(ImageLoadingIndicator)),
      const Size.square(18),
    );
    client.finish(png1x1);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
  });

  testWidgets('ReaderPageImage：页码 + 确定进度，无总长度时不确定', (tester) async {
    await pumpApp(
      tester,
      ReaderPageImage(
        image: SourceImageProvider(
          sourceId: _source,
          ref: const ImageRef(url: _url),
          loader: loader,
        ),
        pageNumber: 3,
      ),
    );
    await tester.pump();
    expect(find.text('3'), findsOneWidget);
    // 尚未收到响应头：不确定进度。
    expect(_indicatorValue(tester), isNull);
    client.progress(750, 1000);
    await _pumpChunk(tester);
    expect(_indicatorValue(tester), 0.75);

    client.finish(png1x1);
    await _settleDecode(tester);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(RawImage), findsOneWidget);
  });

  testWidgets('ReaderPageImage：没有 Content-Length 时不确定进度', (tester) async {
    await pumpApp(
      tester,
      ReaderPageImage(
        image: SourceImageProvider(
          sourceId: _source,
          ref: const ImageRef(url: _url),
          loader: loader,
        ),
        pageNumber: 1,
      ),
    );
    await tester.pump();
    client.progress(12345, null);
    await _pumpChunk(tester);
    expect(_indicatorValue(tester), isNull);
    client.finish(png1x1);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
  });
}
