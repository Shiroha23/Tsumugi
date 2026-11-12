import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/features/novel/novel_routes.dart';
import 'package:tsumugi/features/novel/reader/novel_reader_page.dart';
import 'package:tsumugi/shared/history/history_repository.dart';
import 'package:tsumugi/shared/library/library_item.dart';
import 'package:tsumugi/shared/library/library_repository.dart';
import 'package:tsumugi/sources/model/common.dart';
import 'package:tsumugi/sources/model/content.dart';

import '../../sources/runtime/runtime_support.dart';
import '../app_harness.dart';

/// M3 小说：搜索 → 详情 → 阅读器 → 进度 / 历史 → 继续阅读，书架 / 历史打开小说。
const _sourceId = 'com.example.novel';

/// 含 `/`、`?`、中文的 id，验证路径编码。
const _itemId = '/novel/book/1?from=搜索';

const _detail = Detail(
  id: _itemId,
  title: '青石巷的钟表匠',
  author: '虚构作者丁',
  description: '老钟表匠修好了一只会倒着走的怀表。',
  status: SeriesStatus.completed,
  units: [
    Unit(id: '/novel/book/1/chapter/1', title: '第一章 倒走的怀表'),
    Unit(id: '/novel/book/1/chapter/2', title: '第二章 雨季'),
  ],
);

const _item = LibraryItem(
  sourceId: _sourceId,
  itemId: _itemId,
  title: '青石巷的钟表匠',
  mediaType: MediaType.novel,
);

String _chapterText(String unitId) =>
    [for (var i = 0; i < 40; i++) '$unitId 第$i段${'字' * 40}'].join('\n');

AppHarness _harness() => AppHarness(
  FakeFactory(
    (m) => FakeSource(
      m,
      onSearch: (_, _) async => const PageResult(
        items: [SearchItem(id: _itemId, title: '青石巷的钟表匠', subtitle: '虚构作者丁')],
        hasMore: false,
      ),
      onDetail: (_) async => _detail,
      onContent: (id) async => NovelContent(text: _chapterText(id)),
    ),
  ),
);

Future<void> _pumpFrames(WidgetTester tester, [int n = 10]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('搜索小说进入详情；加入书架；开始阅读', (tester) async {
    final app = _harness();
    await app.install(tester, [
      fakeManifestJson(_sourceId, name: '小说源', type: MediaType.novel),
    ]);
    await app.pump(tester);
    app.router.go('/search');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, '小说'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '钟表');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    await tester.tap(find.text('青石巷的钟表匠'));
    await tester.pumpAndSettle();
    expect(
      app.router.state.uri.toString(),
      NovelRoutes.detail(_sourceId, _itemId),
    );
    expect(find.text('虚构作者丁'), findsOneWidget);
    expect(find.text('已完结'), findsOneWidget);
    expect(find.text('章节（2）'), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, '加入书架'));
    await tester.pumpAndSettle();
    final entry = await tester.runAsync(
      () => LibraryRepository(app.db).get(_sourceId, _itemId),
    );
    expect(entry?.item.mediaType, MediaType.novel);

    await tester.tap(find.widgetWithText(FilledButton, '开始阅读'));
    await tester.pumpAndSettle();
    expect(
      app.router.state.uri.toString(),
      NovelRoutes.reader(_sourceId, _itemId, '/novel/book/1/chapter/1'),
    );
    final reader = tester.widget<NovelReaderPage>(find.byType(NovelReaderPage));
    expect(reader.itemId, _itemId);
    expect(reader.unitId, '/novel/book/1/chapter/1');
    expect(reader.initialPosition, 0);
    await app.dispose(tester);
  });

  testWidgets('阅读器写入字符偏移；详情页“继续阅读”恢复到该位置', (tester) async {
    final app = _harness();
    await app.install(tester, [
      fakeManifestJson(_sourceId, type: MediaType.novel),
    ]);
    await app.pump(tester);
    const unit = '/novel/book/1/chapter/2';
    app.router.push(
      NovelRoutes.reader(_sourceId, _itemId, unit, position: 500),
    );
    await tester.pumpAndSettle();
    expect(find.byType(NovelReaderPage), findsOneWidget);
    // 节流间隔内的写入在计时器到期后完成。
    await _pumpFrames(tester, 15);

    final progress = await tester.runAsync(
      () => HistoryRepository(app.db).latestProgress(_sourceId, _itemId),
    );
    expect(progress?.unitId, unit);
    expect(progress?.unitTitle, '第二章 雨季');
    expect(progress?.position, 500);
    expect(progress?.page, isNull);
    expect(progress?.item.mediaType, MediaType.novel);
    expect(progress?.item.title, '青石巷的钟表匠');

    app.router.pop();
    app.router.push(NovelRoutes.detail(_sourceId, _itemId));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilledButton, '继续阅读'), findsOneWidget);
    expect(find.text('上次读到：第二章 雨季'), findsOneWidget);
    expect(
      find.byWidgetPredicate((w) => w is Icon && w.semanticLabel == '上次读到'),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(FilledButton, '继续阅读'));
    await tester.pumpAndSettle();
    expect(
      app.router.state.uri.toString(),
      NovelRoutes.reader(_sourceId, _itemId, unit, position: 500),
    );
    expect(
      tester
          .widget<NovelReaderPage>(find.byType(NovelReaderPage))
          .initialPosition,
      500,
    );
    await app.dispose(tester);
  });

  testWidgets('读到章节末尾标记已读', (tester) async {
    final app = _harness();
    await app.install(tester, [
      fakeManifestJson(_sourceId, type: MediaType.novel),
    ]);
    await app.pump(tester);
    const unit = '/novel/book/1/chapter/1';
    app.router.push(
      NovelRoutes.reader(_sourceId, _itemId, unit, position: 1 << 20),
    );
    await tester.pumpAndSettle();
    await _pumpFrames(tester, 15);
    final read = await tester.runAsync(
      () => HistoryRepository(app.db).isUnitRead(_sourceId, _itemId, unit),
    );
    expect(read, isTrue);
    await app.dispose(tester);
  });

  testWidgets('书架中的小说进入详情；历史中的小说直接继续阅读', (tester) async {
    final app = _harness();
    await app.install(tester, [
      fakeManifestJson(_sourceId, type: MediaType.novel),
    ]);
    await tester.runAsync(() async {
      await LibraryRepository(app.db).add(_item);
      await HistoryRepository(app.db).recordProgress(
        _item,
        unitId: '/novel/book/1/chapter/2',
        unitTitle: '第二章 雨季',
        position: 321,
      );
    });
    await app.pump(tester);

    await tester.tap(find.text('青石巷的钟表匠'));
    await tester.pumpAndSettle();
    expect(
      app.router.state.uri.toString(),
      NovelRoutes.detail(_sourceId, _itemId),
    );

    app.router.pop();
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(Tab, '历史'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('青石巷的钟表匠'));
    await tester.pumpAndSettle();
    expect(
      app.router.state.uri.toString(),
      NovelRoutes.reader(
        _sourceId,
        _itemId,
        '/novel/book/1/chapter/2',
        position: 321,
      ),
    );
    await app.dispose(tester);
  });
}
