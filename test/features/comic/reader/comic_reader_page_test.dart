import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tsumugi/features/comic/reader/comic_reader_page.dart';
import 'package:tsumugi/features/comic/reader/reader_preferences.dart';
import 'package:tsumugi/features/comic/reader/reader_providers.dart';
import 'package:tsumugi/features/comic/reader/reader_route.dart';
import 'package:tsumugi/shared/image/image_providers.dart';
import 'package:tsumugi/shared/image/source_image_loader.dart';
import 'package:tsumugi/sources/model/common.dart';
import 'package:tsumugi/sources/model/content.dart';
import 'package:tsumugi/sources/model/manifest.dart';
import 'package:tsumugi/sources/source.dart';

import '../../../shared/image/image_fakes.dart';

const _sourceId = 'com.example.comic';
const _itemId = '/comic/book/1';

/// 虚构漫画：3 章，每章若干页（图片地址都在 img.example.com）。
class FakeComicSource implements Source {
  FakeComicSource({this.failFirstContent = false});

  bool failFirstContent;
  bool failFirstDetail = false;
  final contentCalls = <String>[];
  int detailCalls = 0;

  static const chapters = {
    'c1': ('第1话', 3),
    'c2': ('第2话', 2),
    'c3': ('第3话', 4),
  };

  @override
  SourceManifest get manifest => throw UnimplementedError();

  @override
  Future<Detail> detail(String id) async {
    detailCalls++;
    if (failFirstDetail) {
      failFirstDetail = false;
      throw const SourceException(SourceErrorCode.network, '超时');
    }
    return Detail(
      id: id,
      title: '虚构漫画',
      units: [
        for (final MapEntry(:key, :value) in chapters.entries)
          Unit(id: key, title: value.$1),
      ],
    );
  }

  @override
  Future<MediaContent> content(String unitId) async {
    contentCalls.add(unitId);
    if (failFirstContent) {
      failFirstContent = false;
      throw const SourceException(SourceErrorCode.network, '连接失败');
    }
    final count = chapters[unitId]!.$2;
    return ComicContent(
      images: [
        for (var i = 1; i <= count; i++)
          ImageRef(url: 'http://img.example.com/pages/$unitId-$i.png'),
      ],
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late FakeComicSource source;
  late MemoryReaderPreferencesStore prefs;
  late FakeImageClient images;
  late List<ComicReadingProgress> progress;

  setUp(() {
    source = FakeComicSource();
    prefs = MemoryReaderPreferencesStore();
    images = FakeImageClient((_) => png1x1);
    progress = [];
  });

  Future<void> open(
    WidgetTester tester, {
    ReaderMode mode = ReaderMode.leftToRight,
    bool autoNext = false,
    String unitId = 'c1',
    int initialPage = 0,
  }) async {
    prefs.value = ReaderPreferences(mode: mode, autoNextChapter: autoNext);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          comicReaderSourceProvider(_sourceId).overrideWith((ref) => source),
          readerPreferencesStoreProvider.overrideWithValue(prefs),
          sourceImageLoaderProvider.overrideWithValue(
            SourceImageLoader(httpClientFor: (_) => images),
          ),
          comicReaderProgressSinkProvider.overrideWithValue(progress.add),
        ],
        child: MaterialApp(
          home: ComicReaderPage(
            sourceId: _sourceId,
            itemId: _itemId,
            unitId: unitId,
            initialPage: initialPage,
          ),
        ),
      ),
    );
    await settle(tester);
  }

  Future<void> key(WidgetTester tester, LogicalKeyboardKey k) async {
    await tester.sendKeyEvent(k);
    await settle(tester);
  }

  /// 图片在 FakeAsync 中不会完成解码，页面一直有进度动画，所以不用 pumpAndSettle。
  Future<void> tapAt(WidgetTester tester, Offset at) async {
    await tester.tapAt(at);
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
    await settle(tester);
  }

  Size screen(WidgetTester tester) =>
      tester.view.physicalSize / tester.view.devicePixelRatio;

  ComicReadingProgress last() => progress.last;

  group('paged (left to right)', () {
    testWidgets('loads the chapter and reports progress with title', (
      tester,
    ) async {
      await open(tester);
      expect(find.text('1 / 3'), findsOneWidget);
      expect(source.contentCalls, ['c1']);
      expect(
        last(),
        const ComicReadingProgress(
          sourceId: _sourceId,
          itemId: _itemId,
          unitId: 'c1',
          unitTitle: '第1话',
          pageIndex: 0,
          pageCount: 3,
        ),
      );
    });

    testWidgets('keyboard and tap zones turn pages', (tester) async {
      await open(tester);
      await key(tester, LogicalKeyboardKey.arrowRight);
      expect(find.text('2 / 3'), findsOneWidget);
      expect(last().pageIndex, 1);

      await key(tester, LogicalKeyboardKey.arrowLeft);
      expect(find.text('1 / 3'), findsOneWidget);

      await key(tester, LogicalKeyboardKey.space);
      await key(tester, LogicalKeyboardKey.pageDown);
      expect(find.text('3 / 3'), findsOneWidget);

      final size = screen(tester);
      await tapAt(tester, Offset(size.width * 0.1, size.height / 2));
      expect(find.text('2 / 3'), findsOneWidget);
      await tapAt(tester, Offset(size.width * 0.9, size.height / 2));
      expect(find.text('3 / 3'), findsOneWidget);
      expect(progress.map((p) => p.pageIndex), [0, 1, 0, 1, 2, 1, 2]);
    });

    testWidgets('mouse wheel turns pages', (tester) async {
      await open(tester);
      final center = tester.getCenter(find.byType(ComicReaderPage));
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(pointer.hover(center));
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 120)));
      await settle(tester);
      expect(find.text('2 / 3'), findsOneWidget);
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, -120)));
      await settle(tester);
      expect(find.text('1 / 3'), findsOneWidget);
    });

    testWidgets('manual next chapter at the end', (tester) async {
      await open(tester);
      for (var i = 0; i < 3; i++) {
        await key(tester, LogicalKeyboardKey.arrowRight);
      }
      expect(find.text('本章完'), findsWidgets);
      expect(find.text('下一章：第2话'), findsOneWidget);
      expect(source.contentCalls, ['c1']);

      await key(tester, LogicalKeyboardKey.arrowRight);
      expect(source.contentCalls, ['c1', 'c2']);
      expect(find.text('1 / 2'), findsOneWidget);
      expect(last().unitId, 'c2');
      expect(last().unitTitle, '第2话');
      expect(last().pageIndex, 0);
      // 章节列表只取一次。
      expect(source.detailCalls, 1);
    });

    testWidgets('next chapter button on the end page', (tester) async {
      await open(tester);
      for (var i = 0; i < 3; i++) {
        await key(tester, LogicalKeyboardKey.arrowRight);
      }
      await tester.tap(find.text('下一章：第2话'));
      await settle(tester);
      expect(last().unitId, 'c2');
    });

    testWidgets('automatic next chapter', (tester) async {
      await open(tester, autoNext: true);
      for (var i = 0; i < 3; i++) {
        await key(tester, LogicalKeyboardKey.arrowRight);
      }
      expect(source.contentCalls, ['c1', 'c2']);
      expect(find.text('1 / 2'), findsOneWidget);
    });

    testWidgets('previous chapter opens at its last page', (tester) async {
      await open(tester, unitId: 'c2');
      await key(tester, LogicalKeyboardKey.arrowLeft);
      expect(source.contentCalls, ['c2', 'c1']);
      expect(find.text('3 / 3'), findsOneWidget);
      expect(last().unitId, 'c1');
      expect(last().pageIndex, 2);
    });

    testWidgets('chapter list failure can be retried from the end page', (
      tester,
    ) async {
      source.failFirstDetail = true;
      await open(tester);
      for (var i = 0; i < 3; i++) {
        await key(tester, LogicalKeyboardKey.arrowRight);
      }
      expect(find.text('章节列表加载失败'), findsOneWidget);
      expect(find.text('已经是最后一章'), findsNothing);
      await tester.tap(find.text('重试获取章节'));
      await settle(tester);
      expect(source.detailCalls, 2);
      expect(find.text('下一章：第2话'), findsOneWidget);
    });

    testWidgets('next key retries a failed chapter list', (tester) async {
      source.failFirstDetail = true;
      await open(tester);
      for (var i = 0; i < 4; i++) {
        await key(tester, LogicalKeyboardKey.arrowRight);
      }
      expect(find.text('章节列表加载失败，正在重试'), findsOneWidget);
      expect(source.detailCalls, 2);
      await key(tester, LogicalKeyboardKey.arrowRight);
      expect(last().unitId, 'c2');
    });

    testWidgets('mouse wheel works on the end page', (tester) async {
      await open(tester);
      for (var i = 0; i < 3; i++) {
        await key(tester, LogicalKeyboardKey.arrowRight);
      }
      expect(find.text('下一章：第2话'), findsOneWidget);
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(pointer.hover(const Offset(100, 100)));
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, -120)));
      await settle(tester);
      expect(find.text('3 / 3'), findsOneWidget);
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 120)));
      await settle(tester);
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 120)));
      await settle(tester);
      expect(last().unitId, 'c2');
    });

    testWidgets('first chapter has no previous chapter', (tester) async {
      await open(tester);
      await key(tester, LogicalKeyboardKey.arrowLeft);
      expect(find.text('已经是第一章'), findsOneWidget);
      expect(source.contentCalls, ['c1']);
    });

    testWidgets('opens at the initial page', (tester) async {
      await open(tester, unitId: 'c3', initialPage: 2);
      expect(find.text('3 / 4'), findsOneWidget);
      expect(last().pageIndex, 2);
      expect(progress, hasLength(1));
    });

    testWidgets('preloads following pages', (tester) async {
      await open(tester, unitId: 'c3');
      // 当前页 + 之后 3 页（默认 preloadPages = 3）。
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      final urls = images.requests.map((r) => r.url).toSet();
      expect(urls, {
        for (var i = 1; i <= 4; i++) 'http://img.example.com/pages/c3-$i.png',
      });
    });
  });

  testWidgets('double tap zooms and locks page swiping', (tester) async {
    await open(tester);
    final center = tester.getCenter(find.byType(ComicReaderPage));
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(center);
    await settle(tester);
    final viewer = tester.widget<InteractiveViewer>(
      find.byType(InteractiveViewer).first,
    );
    expect(
      viewer.transformationController!.value.getMaxScaleOnAxis(),
      greaterThan(1),
    );
    final pageView = tester.widget<PageView>(find.byType(PageView));
    expect(pageView.physics, isA<NeverScrollableScrollPhysics>());
    // 双击不会切换工具栏。
    expect(find.byTooltip('阅读设置'), findsNothing);

    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(center);
    await settle(tester);
    expect(viewer.transformationController!.value.getMaxScaleOnAxis(), 1);
  });

  testWidgets('right to left: left arrow goes forward', (tester) async {
    await open(tester, mode: ReaderMode.rightToLeft);
    await key(tester, LogicalKeyboardKey.arrowLeft);
    expect(find.text('2 / 3'), findsOneWidget);
    await key(tester, LogicalKeyboardKey.arrowRight);
    expect(find.text('1 / 3'), findsOneWidget);
    final size = screen(tester);
    await tapAt(tester, Offset(size.width * 0.1, size.height / 2));
    expect(find.text('2 / 3'), findsOneWidget);
  });

  group('vertical', () {
    testWidgets('scrolls with keys and tracks the current page', (
      tester,
    ) async {
      await open(tester, mode: ReaderMode.vertical);
      expect(find.byType(ListView), findsOneWidget);
      expect(find.text('1 / 3'), findsOneWidget);
      // 默认宽高比 0.7 → 每页高约 1143，视口 600；两次下翻进入第 2 页。
      await key(tester, LogicalKeyboardKey.pageDown);
      await key(tester, LogicalKeyboardKey.arrowDown);
      expect(find.text('2 / 3'), findsOneWidget);
      expect(last().pageIndex, 1);
    });

    testWidgets('opens at the initial page', (tester) async {
      await open(tester, mode: ReaderMode.vertical, initialPage: 2);
      await settle(tester);
      expect(find.text('3 / 3'), findsOneWidget);
      final list = tester.widget<ListView>(find.byType(ListView));
      expect(list.controller!.offset, greaterThan(2000));
    });

    testWidgets('decoded images resize pages to their aspect ratio', (
      tester,
    ) async {
      await open(tester, mode: ReaderMode.vertical);
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pump();
      }
      expect(find.byType(RawImage), findsWidgets);
      // 1×1 图片 → 页高 = 视口宽度。
      final first = tester.getSize(find.byType(RawImage).first);
      expect(first.height, closeTo(screen(tester).width, 0.5));
      expect(tester.takeException(), isNull);
    });

    testWidgets('next key at the bottom opens the next chapter', (
      tester,
    ) async {
      await open(tester, mode: ReaderMode.vertical);
      for (var i = 0; i < 20 && source.contentCalls.length < 2; i++) {
        await key(tester, LogicalKeyboardKey.pageDown);
      }
      expect(source.contentCalls, ['c1', 'c2']);
      expect(last().unitId, 'c2');
    });
  });

  testWidgets('toolbar switches mode and remembers it', (tester) async {
    await open(tester, mode: ReaderMode.vertical);
    final size = screen(tester);
    await tapAt(tester, Offset(size.width / 2, size.height / 2));
    expect(find.text('第1话'), findsOneWidget);
    expect(find.text('虚构漫画'), findsOneWidget);

    await tester.tap(find.byTooltip('阅读设置'));
    await settle(tester);
    await tester.tap(
      find.ancestor(
        of: find.text('右→左翻页'),
        matching: find.byType(CheckedPopupMenuItem<Object>),
      ),
    );
    await settle(tester);

    expect(prefs.value.mode, ReaderMode.rightToLeft);
    expect(find.byType(PageView), findsOneWidget);
    expect(find.byType(ListView), findsNothing);
  });

  testWidgets('toolbar slider jumps to a page', (tester) async {
    await open(tester, unitId: 'c3');
    final size = screen(tester);
    await tapAt(tester, Offset(size.width / 2, size.height / 2));
    final slider = find.byType(Slider);
    expect(slider, findsOneWidget);
    // 拖到最右端 → 最后一页。
    await tester.drag(slider, const Offset(2000, 0));
    await settle(tester);
    expect(last().pageIndex, 3);
    expect(find.text('4 / 4'), findsOneWidget);
  });

  testWidgets('chapter error shows retry', (tester) async {
    source.failFirstContent = true;
    await open(tester);
    expect(find.textContaining('章节加载失败'), findsOneWidget);
    expect(find.textContaining('连接失败'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await settle(tester);
    expect(find.text('1 / 3'), findsOneWidget);
    expect(source.contentCalls, ['c1', 'c1']);
  });

  testWidgets('route location round-trips ids containing slashes', (
    tester,
  ) async {
    final location = comicReaderLocation(
      _sourceId,
      '/comic/book/1?x=1',
      '/comic/book/1/chapter/2',
      page: 5,
    );
    expect(location, startsWith('/comic/com.example.comic/%2Fcomic%2Fbook'));
    late GoRouterState captured;
    final router = GoRouter(
      initialLocation: location,
      routes: [
        GoRoute(
          path: comicReaderRoutePath,
          builder: (_, state) {
            captured = state;
            return const SizedBox();
          },
        ),
      ],
    );
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    final page = comicReaderPageFromState(captured);
    expect(page.sourceId, _sourceId);
    expect(page.itemId, '/comic/book/1?x=1');
    expect(page.unitId, '/comic/book/1/chapter/2');
    expect(page.initialPage, 5);
    router.dispose();
  });
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
