import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/storage/app_database.dart';
import 'package:tsumugi/features/library/library_page.dart';
import 'package:tsumugi/features/library/open_item.dart';
import 'package:tsumugi/shared/history/providers.dart';
import 'package:tsumugi/shared/library/providers.dart';
import 'package:tsumugi/sources/model/common.dart';

import '../../core/storage/test_database.dart';

LibraryItem item(String id, {MediaType type = MediaType.comic}) => LibraryItem(
  sourceId: 'com.example.comic',
  itemId: id,
  title: '作品 $id',
  mediaType: type,
);

void main() {
  late AppDatabase db;
  late LibraryRepository library;
  late HistoryRepository history;

  setUp(() {
    db = openTestDatabase();
    library = LibraryRepository(db);
    history = HistoryRepository(db);
  });
  tearDown(() => db.close());

  Future<void> pumpPage(WidgetTester tester, {OpenLibraryItem? open}) async {
    tester.view.physicalSize = const Size(800, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          openItemProvider.overrideWithValue(open),
        ],
        child: const MaterialApp(home: LibraryPage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 卸载页面，让 drift 的 stream 在测试结束前关闭。
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  }

  Future<void> openHistoryTab(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(Tab, '历史'));
    await tester.pumpAndSettle();
  }

  testWidgets('空书架与空历史', (tester) async {
    await pumpPage(tester);
    expect(find.text('书架是空的'), findsOneWidget);
    expect(find.byTooltip('清空历史'), findsNothing);

    await openHistoryTab(tester);
    expect(find.text('还没有阅读记录'), findsOneWidget);
    expect(find.byTooltip('清空历史'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('网格展示条目并按类型筛选', (tester) async {
    await tester.runAsync(() async {
      await library.add(item('a'));
      await library.add(item('b', type: MediaType.novel));
    });
    await pumpPage(tester);
    expect(find.text('作品 a'), findsOneWidget);
    expect(find.text('作品 b'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, '小说'));
    await tester.pumpAndSettle();
    expect(find.text('作品 a'), findsNothing);
    expect(find.text('作品 b'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, '视频'));
    await tester.pumpAndSettle();
    expect(find.text('书架里还没有视频'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('窄屏 + 放大字号时两行标题不溢出', (tester) async {
    await tester.runAsync(() async {
      for (final id in ['a', 'b', 'c']) {
        await library.add(
          LibraryItem(
            sourceId: 'com.example.comic',
            itemId: id,
            title: '一个很长很长很长很长很长很长很长的标题 $id',
            mediaType: MediaType.comic,
          ),
        );
      }
    });
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDatabaseProvider.overrideWithValue(db)],
        child: const MediaQuery(
          data: MediaQueryData(
            size: Size(360, 740),
            textScaler: TextScaler.linear(1.3),
          ),
          child: MaterialApp(home: LibraryPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('很长的标题'), findsNWidgets(3));
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('长按移出书架', (tester) async {
    await tester.runAsync(() => library.add(item('a')));
    await pumpPage(tester);

    await tester.longPress(find.text('作品 a'));
    await tester.pumpAndSettle();
    expect(find.text('移出书架'), findsOneWidget);
    // 取消不移出。
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('作品 a'), findsOneWidget);

    await tester.longPress(find.text('作品 a'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '移出'));
    await tester.pumpAndSettle();
    expect(find.text('书架是空的'), findsOneWidget);
    expect(find.text('已移出「作品 a」'), findsOneWidget);
    expect(
      await tester.runAsync(() => library.contains('com.example.comic', 'a')),
      isFalse,
    );
    await unmount(tester);
  });

  testWidgets('点击条目调用 openItemProvider；未接入时提示', (tester) async {
    await tester.runAsync(() => library.add(item('a')));
    final opened = <(LibraryItem, ItemProgress?)>[];
    await pumpPage(
      tester,
      open: (context, item, {progress}) => opened.add((item, progress)),
    );
    await tester.tap(find.text('作品 a'));
    await tester.pumpAndSettle();
    expect(opened.single.$1, item('a'));
    expect(opened.single.$2, isNull);
    await unmount(tester);

    await pumpPage(tester);
    await tester.tap(find.text('作品 a'));
    await tester.pumpAndSettle();
    expect(find.text('详情页暂不可用'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('历史列出最近阅读与进度，可删除与清空', (tester) async {
    await tester.runAsync(() async {
      await history.recordProgress(
        item('a'),
        unitId: 'c3',
        unitTitle: '第 3 话',
        page: 11,
        pageCount: 20,
      );
      await history.recordProgress(item('b'), unitId: 'c1', unitTitle: '第 1 话');
    });
    final opened = <(LibraryItem, ItemProgress?)>[];
    await pumpPage(
      tester,
      open: (context, item, {progress}) => opened.add((item, progress)),
    );
    await openHistoryTab(tester);

    expect(find.text('作品 a'), findsOneWidget);
    expect(find.textContaining('第 3 话 · 第 12/20 页'), findsOneWidget);
    expect(find.textContaining('刚刚'), findsNWidgets(2));

    await tester.tap(find.text('作品 a'));
    await tester.pumpAndSettle();
    expect(opened.single.$2?.unitId, 'c3');

    await tester.tap(
      find.descendant(
        of: find.widgetWithText(ListTile, '作品 b'),
        matching: find.byTooltip('删除记录'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('作品 b'), findsNothing);

    await tester.tap(find.byTooltip('清空历史'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '清空'));
    await tester.pumpAndSettle();
    expect(find.text('还没有阅读记录'), findsOneWidget);
    await unmount(tester);
  });

  test('relativeTime', () {
    final now = DateTime(2026, 11, 12, 12);
    expect(relativeTime(now, now), '刚刚');
    expect(
      relativeTime(now.subtract(const Duration(minutes: 5)), now),
      '5 分钟前',
    );
    expect(relativeTime(now.subtract(const Duration(hours: 3)), now), '3 小时前');
    expect(relativeTime(now.subtract(const Duration(days: 2)), now), '2 天前');
    expect(relativeTime(DateTime(2026, 1, 2), now), '2026-01-02');
  });
}
