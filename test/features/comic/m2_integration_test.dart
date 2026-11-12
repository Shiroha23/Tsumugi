import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/features/comic/detail/comic_routes.dart';
import 'package:tsumugi/features/comic/reader/comic_reader_page.dart';
import 'package:tsumugi/features/comic/reader/reader_route.dart';
import 'package:tsumugi/shared/history/history_repository.dart';
import 'package:tsumugi/shared/library/library_item.dart';
import 'package:tsumugi/shared/library/library_repository.dart';
import 'package:tsumugi/sources/model/common.dart';
import 'package:tsumugi/sources/model/content.dart';

import '../../sources/runtime/runtime_support.dart';
import '../app_harness.dart';

/// M2 集成：详情页 ⇄ 书架、阅读器 → 进度 / 历史、书架 / 历史 → 详情 / 阅读器。
const _sourceId = 'com.example.a';
const _itemId = '/comic/book/1';

const _detail = Detail(
  id: _itemId,
  title: '星之栖处',
  cover: 'http://img.example.com/covers/1.png',
  units: [
    Unit(id: 'c1', title: '第 1 话'),
    Unit(id: 'c2', title: '第 2 话'),
    Unit(id: 'c3', title: '第 3 话'),
  ],
);

const _libraryItem = LibraryItem(
  sourceId: _sourceId,
  itemId: _itemId,
  title: '星之栖处',
  mediaType: MediaType.comic,
);

AppHarness _harness() => AppHarness(
  FakeFactory(
    (m) => FakeSource(
      m,
      onDetail: (id) async => _detail,
      onContent: (unitId) async => ComicContent(
        images: [
          for (var i = 0; i < 3; i++)
            ImageRef(url: 'http://img.example.com/pages/$unitId-$i.png'),
        ],
      ),
    ),
  ),
);

/// 阅读器有持续的加载动画（图片失败占位前的进度），不能 pumpAndSettle。
Future<void> _pumpFrames(WidgetTester tester, [int n = 10]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('详情页加入 / 移出书架', (tester) async {
    final app = _harness();
    await app.install(tester, [fakeManifestJson(_sourceId)]);
    await app.pump(tester);
    app.router.push(ComicRoutes.detail(_sourceId, _itemId));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, '加入书架'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(OutlinedButton, '已在书架'), findsOneWidget);
    final entry = await tester.runAsync(
      () => LibraryRepository(app.db).get(_sourceId, _itemId),
    );
    expect(entry?.item.title, '星之栖处');
    expect(entry?.item.mediaType, MediaType.comic);
    expect(entry?.item.cover, _detail.cover);

    await tester.tap(find.widgetWithText(OutlinedButton, '已在书架'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(OutlinedButton, '加入书架'), findsOneWidget);
    expect(
      await tester.runAsync(
        () => LibraryRepository(app.db).contains(_sourceId, _itemId),
      ),
      isFalse,
    );
    await app.dispose(tester);
  });

  testWidgets('阅读器写入进度；详情页据此“继续阅读”并标记章节', (tester) async {
    final app = _harness();
    await app.install(tester, [fakeManifestJson(_sourceId)]);
    await app.pump(tester);

    app.router.push(comicReaderLocation(_sourceId, _itemId, 'c2', page: 1));
    await _pumpFrames(tester);
    expect(find.byType(ComicReaderPage), findsOneWidget);
    // 节流间隔内的写入在计时器到期后完成。
    await _pumpFrames(tester, 15);

    final progress = await tester.runAsync(
      () => HistoryRepository(app.db).latestProgress(_sourceId, _itemId),
    );
    expect(progress?.unitId, 'c2');
    expect(progress?.unitTitle, '第 2 话');
    expect(progress?.page, 1);
    expect(progress?.pageCount, 3);
    expect(progress?.item.title, '星之栖处');

    // 回到详情页：继续阅读指向上次的章节与页码。
    app.router.pop();
    app.router.push(ComicRoutes.detail(_sourceId, _itemId));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilledButton, '继续阅读'), findsOneWidget);
    expect(find.text('上次读到：第 2 话 第 2 页'), findsOneWidget);
    expect(
      find.byWidgetPredicate((w) => w is Icon && w.semanticLabel == '上次读到'),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(FilledButton, '继续阅读'));
    await _pumpFrames(tester);
    expect(
      app.router.state.uri.toString(),
      comicReaderLocation(_sourceId, _itemId, 'c2', page: 1),
    );
    await app.dispose(tester);
  });

  testWidgets('书架条目进入详情；历史条目直接继续阅读', (tester) async {
    final app = _harness();
    await app.install(tester, [fakeManifestJson(_sourceId)]);
    await tester.runAsync(() async {
      await LibraryRepository(app.db).add(_libraryItem);
      await HistoryRepository(app.db).recordProgress(
        _libraryItem,
        unitId: 'c3',
        unitTitle: '第 3 话',
        page: 2,
        pageCount: 3,
      );
    });
    await app.pump(tester);

    await tester.tap(find.text('星之栖处'));
    await tester.pumpAndSettle();
    expect(
      app.router.state.uri.toString(),
      ComicRoutes.detail(_sourceId, _itemId),
    );

    app.router.pop();
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(Tab, '历史'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('星之栖处'));
    await _pumpFrames(tester);
    expect(
      app.router.state.uri.toString(),
      comicReaderLocation(_sourceId, _itemId, 'c3', page: 2),
    );
    await app.dispose(tester);
  });
}
