import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/features/comic/detail/comic_routes.dart';
import 'package:tsumugi/features/explore/explore_preferences.dart';
import 'package:tsumugi/features/novel/novel_routes.dart';
import 'package:tsumugi/sources/model/common.dart';
import 'package:tsumugi/sources/model/manifest.dart';
import 'package:tsumugi/sources/source.dart';

import '../../sources/runtime/runtime_support.dart';
import '../app_harness.dart';

const _star = SearchItem(id: '/comic/book/1', title: '星之栖处', subtitle: '虚构作者甲');
const _lighthouse = SearchItem(id: '/comic/book/3', title: '灯塔与猫');
const _novel = SearchItem(id: '/novel/book/1', title: '纸上远行');

PageResult<SearchItem> _page(List<SearchItem> items, {bool more = false}) =>
    PageResult(items: items, hasMore: more);

/// 源甲（漫画）：「最新」两页、「排行」为空；小说源：一个分类；源乙：分类加载失败一次。
FakeSource Function(SourceManifest) _build({
  int categoryFailures = 0,
  int listFailures = 0,
  bool failSecondPage = false,
}) {
  var categoryCalls = 0;
  var listCalls = 0;
  return (m) => switch (m.id) {
    'com.example.a' => FakeSource(
      m,
      onExplore: () async {
        if (categoryCalls++ < categoryFailures) {
          throw const SourceException(SourceErrorCode.http, null, 502);
        }
        return const [
          ExploreCategory(id: 'latest', name: '最新'),
          ExploreCategory(id: 'rank', name: '排行'),
        ];
      },
      onExploreList: (id, page) async {
        if (listCalls++ < listFailures) {
          throw const SourceException(SourceErrorCode.challenge);
        }
        return switch ((id, page)) {
          ('latest', 1) => _page([_star], more: true),
          ('latest', 2) when failSecondPage => throw const SourceException(
            SourceErrorCode.network,
          ),
          ('latest', 2) => _page([_lighthouse]),
          _ => _page([]),
        };
      },
      onDetail: (id) async => Detail(id: id, title: '星之栖处', author: '虚构作者甲'),
    ),
    'com.example.novel' => FakeSource(
      m,
      onExplore: () async => const [
        ExploreCategory(id: 'all', name: '全部'),
        ExploreCategory(id: 'done', name: '完结'),
      ],
      onExploreList: (id, page) async => id == 'done'
          ? _page([const SearchItem(id: '/novel/book/2', title: '完结之书')])
          : _page([_novel]),
      onDetail: (id) async => Detail(id: id, title: '纸上远行'),
    ),
    _ => FakeSource(m),
  };
}

Future<AppHarness> _open(
  WidgetTester tester,
  FakeSource Function(SourceManifest) build, {
  ExploreSelection saved = const ExploreSelection(),
}) async {
  final app = AppHarness(
    FakeFactory(build),
    explorePreferences: MemoryExplorePreferencesStore(saved),
  );
  await app.install(tester, [
    fakeManifestJson('com.example.a', name: '源甲', explore: true),
    fakeManifestJson(
      'com.example.novel',
      name: '小说源',
      type: MediaType.novel,
      explore: true,
    ),
    fakeManifestJson('com.example.plain', name: '源丙'),
    fakeManifestJson('com.example.off', name: '源丁', explore: true),
  ]);
  await tester.runAsync(
    () => app.registry.setEnabled('com.example.off', false),
  );
  await app.pump(tester);
  app.router.go('/explore');
  await tester.pumpAndSettle();
  return app;
}

FakeSource _created(AppHarness app, String id) =>
    app.factory.created.singleWhere((s) => s.manifest.id == id);

void main() {
  testWidgets('选源 → 分类 → 翻页 → 点击进入详情；记住选择', (tester) async {
    final app = await _open(tester, _build());

    // 默认第一个源与它的第一个分类。
    expect(find.text('源甲（漫画）'), findsOneWidget);
    expect(find.text('星之栖处'), findsOneWidget);
    expect(find.text('加载更多'), findsOneWidget);

    await tester.tap(find.text('加载更多'));
    await tester.pumpAndSettle();
    expect(find.text('灯塔与猫'), findsOneWidget);
    expect(find.text('加载更多'), findsNothing);
    final a = _created(app, 'com.example.a');
    expect(a.exploreLists, [('latest', 1), ('latest', 2)]);

    await tester.tap(find.text('排行'));
    await tester.pumpAndSettle();
    expect(find.text('这个分类暂时没有内容'), findsOneWidget);
    expect(
      app.explorePreferences.value,
      const ExploreSelection(sourceId: 'com.example.a', categoryId: 'rank'),
    );

    // 只列出启用且提供发现页的源。
    await tester.tap(find.byKey(const ValueKey('explore-source')));
    await tester.pumpAndSettle();
    expect(find.text('小说源（小说）'), findsOneWidget);
    expect(find.textContaining('源丙'), findsNothing);
    expect(find.textContaining('源丁'), findsNothing);
    await tester.tap(find.text('小说源（小说）'));
    await tester.pumpAndSettle();
    expect(find.text('纸上远行'), findsOneWidget);
    expect(
      app.explorePreferences.value,
      const ExploreSelection(sourceId: 'com.example.novel', categoryId: 'all'),
    );

    // 按源类型进入详情页。
    await tester.tap(find.text('纸上远行'));
    await tester.pumpAndSettle();
    expect(
      app.router.state.uri.toString(),
      NovelRoutes.detail('com.example.novel', '/novel/book/1'),
    );
    expect(_created(app, 'com.example.novel').details, ['/novel/book/1']);

    await app.dispose(tester);
  });

  testWidgets('漫画条目进入漫画详情', (tester) async {
    final app = await _open(tester, _build());
    await tester.tap(find.text('星之栖处'));
    await tester.pumpAndSettle();
    expect(
      app.router.state.uri.toString(),
      ComicRoutes.detail('com.example.a', '/comic/book/1'),
    );
    expect(find.text('虚构作者甲'), findsOneWidget);
    await app.dispose(tester);
  });

  testWidgets('恢复上次选择的源与分类', (tester) async {
    final app = await _open(
      tester,
      _build(),
      saved: const ExploreSelection(
        sourceId: 'com.example.novel',
        categoryId: 'done',
      ),
    );
    expect(find.text('小说源（小说）'), findsOneWidget);
    expect(find.text('完结之书'), findsOneWidget);
    final chip = tester.widget<ChoiceChip>(
      find.byKey(const ValueKey('explore-category-done')),
    );
    expect(chip.selected, isTrue);
    expect(app.factory.created.map((s) => s.manifest.id), [
      'com.example.novel',
    ]);
    await app.dispose(tester);
  });

  testWidgets('分类加载失败可重试；列表需要验证时可打开验证页', (tester) async {
    final app = await _open(
      tester,
      _build(categoryFailures: 1, listFailures: 1),
    );
    expect(find.text('服务器返回错误（HTTP 502）'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    // 第一页 E_CHALLENGE：打开验证页，完成后自动重试。
    expect(find.text('需要验证'), findsOneWidget);
    await tester.tap(find.text('打开验证页'));
    await tester.pumpAndSettle();
    expect(app.verification.calls, ['com.example.a']);
    expect(find.text('星之栖处'), findsOneWidget);
    final a = _created(app, 'com.example.a');
    expect(a.explores, 2);
    expect(a.exploreLists, [('latest', 1), ('latest', 1)]);
    await app.dispose(tester);
  });

  testWidgets('翻页失败保留已加载的条目，可重试', (tester) async {
    final app = await _open(tester, _build(failSecondPage: true));
    await tester.tap(find.text('加载更多'));
    await tester.pumpAndSettle();
    expect(find.text('星之栖处'), findsOneWidget);
    expect(find.text('网络错误或超时'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(_created(app, 'com.example.a').exploreLists, [
      ('latest', 1),
      ('latest', 2),
      ('latest', 2),
    ]);
    await app.dispose(tester);
  });

  testWidgets('没有提供发现页的源时提示导入', (tester) async {
    final app = AppHarness(FakeFactory(_build()));
    await app.install(tester, [fakeManifestJson('com.example.plain')]);
    await app.pump(tester);
    app.router.go('/explore');
    await tester.pumpAndSettle();
    expect(find.textContaining('没有提供发现页的已启用源'), findsOneWidget);
    await app.dispose(tester);
  });
}
