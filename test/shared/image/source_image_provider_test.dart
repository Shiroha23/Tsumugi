import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/shared/image/image_providers.dart';
import 'package:tsumugi/shared/image/source_image.dart';
import 'package:tsumugi/shared/image/source_image_loader.dart';
import 'package:tsumugi/shared/image/source_image_provider.dart';
import 'package:tsumugi/sources/model/content.dart';

import 'image_fakes.dart';

void main() {
  test('equality uses sourceId + url + loader', () {
    final loader = SourceImageLoader(httpClientFor: (_) => throw 'unused');
    SourceImageProvider p(String s, String u, [Map<String, String>? h]) =>
        SourceImageProvider(
          sourceId: s,
          ref: ImageRef(url: u, headers: h),
          loader: loader,
        );
    expect(p('a', 'u'), p('a', 'u', {'Referer': 'x'}));
    expect(p('a', 'u').hashCode, p('a', 'u').hashCode);
    expect(p('a', 'u'), isNot(p('b', 'u')));
    expect(p('a', 'u'), isNot(p('a', 'v')));
  });

  testWidgets('decodes bytes from the loader', (tester) async {
    final client = FakeImageClient((_) => png1x1);
    final provider = SourceImageProvider(
      sourceId: 'com.example.comic',
      ref: const ImageRef(
        url: 'http://img.example.com/pages/1.png',
        headers: {'Referer': 'http://comic.example.com/'},
      ),
      loader: SourceImageLoader(httpClientFor: (_) => client),
    );
    final info = await tester.runAsync(() async {
      final stream = provider.resolve(ImageConfiguration.empty);
      final done = Completer<ImageInfo>();
      stream.addListener(
        ImageStreamListener(
          (i, _) => done.complete(i),
          onError: (e, st) => done.completeError(e, st),
        ),
      );
      return done.future;
    });
    expect(info!.image.width, 1);
    expect(
      client.requests.single.headers['Referer'],
      'http://comic.example.com/',
    );
    info.dispose();
    provider.evict();
  });

  testWidgets('undecodable bytes are evicted from the loader cache', (
    tester,
  ) async {
    final client = FakeImageClient(
      (_) => Uint8List.fromList(utf8.encode('<html>')),
    );
    final loader = SourceImageLoader(httpClientFor: (_) => client);
    const ref = ImageRef(url: 'http://img.example.com/pages/bad.png');
    final provider = SourceImageProvider(
      sourceId: 's',
      ref: ref,
      loader: loader,
    );
    final error = await tester.runAsync(() async {
      final done = Completer<Object>();
      provider
          .resolve(ImageConfiguration.empty)
          .addListener(
            ImageStreamListener((_, _) {}, onError: (e, _) => done.complete(e)),
          );
      return done.future;
    });
    expect(error, isNotNull);
    expect(loader.memoryCache.length, 0);
  });

  testWidgets('CoverImage shows a placeholder without url', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Center(child: CoverImage(sourceId: 's', url: null, width: 90)),
        ),
      ),
    );
    expect(find.byIcon(Icons.image_outlined), findsOneWidget);
  });

  testWidgets('SourceImage uses the global loader provider', (tester) async {
    final client = FakeImageClient((_) => png1x1);
    final loader = SourceImageLoader(httpClientFor: (_) => client);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sourceImageLoaderProvider.overrideWithValue(loader)],
        child: const MaterialApp(
          home: CoverImage(
            sourceId: 'com.example.comic',
            url: 'http://img.example.com/covers/1.png',
            headers: {'Referer': 'http://comic.example.com/'},
            width: 90,
          ),
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    expect(client.requests.single.url, 'http://img.example.com/covers/1.png');
    expect(
      client.requests.single.headers['Referer'],
      'http://comic.example.com/',
    );
  });
}
