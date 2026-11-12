import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/features/comic/detail/comic_routes.dart';
import 'package:tsumugi/sources/model/common.dart';
import 'package:tsumugi/sources/model/manifest.dart';
import 'package:tsumugi/sources/source.dart';

import '../../sources/runtime/runtime_support.dart';
import '../app_harness.dart';

const _star = SearchItem(
  id: '/comic/book/1',
  title: '星之栖处',
  subtitle: '虚构作者甲',
  cover: 'http://img.example.com/covers/1.png',
  coverHeaders: {'Referer': 'http://comic.example.com/'},
);

FakeSource _build(SourceManifest m) => switch (m.id) {
  'com.example.a' => FakeSource(
    m,
    onSearch: (kw, page) async => page == 1
        ? const PageResult(items: [_star], hasMore: true)
        : const PageResult(
            items: [SearchItem(id: '/comic/book/3', title: '灯塔与猫')],
            hasMore: false,
          ),
    onDetail: (id) async => Detail(id: id, title: '星之栖处', author: '虚构作者甲'),
  ),
  'com.example.b' => FakeSource(
    m,
    onSearch: (_, _) =>
        Future.error(const SourceException(SourceErrorCode.challenge)),
  ),
  _ => FakeSource(
    m,
    onSearch: (_, _) =>
        Future.error(const SourceException(SourceErrorCode.http, null, 502)),
  ),
};

void main() {
  testWidgets('结果按源分组；失败只显示在该分组；分页；点击进入详情', (tester) async {
    final app = AppHarness(FakeFactory(_build));
    await app.install(tester, [
      fakeManifestJson('com.example.a', name: '源甲'),
      fakeManifestJson('com.example.b', name: '源乙'),
      fakeManifestJson('com.example.c', name: '源丙'),
      fakeManifestJson('com.example.novel', name: '小说源', type: MediaType.novel),
    ]);
    await app.pump(tester);
    app.router.go('/search');
    await tester.pumpAndSettle();
    expect(find.text('输入关键词，在所有已启用的源中搜索'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '星');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(find.text('源甲'), findsOneWidget);
    expect(find.text('源乙'), findsOneWidget);
    expect(find.text('源丙'), findsOneWidget);
    expect(find.text('小说源'), findsNothing);
    expect(find.text('星之栖处'), findsOneWidget);
    expect(find.text('1+ 条'), findsOneWidget);
    expect(find.text('需要验证'), findsOneWidget);
    expect(find.text('打开验证页'), findsOneWidget);
    expect(find.text('服务器返回错误（HTTP 502）'), findsOneWidget);
    expect(find.text('重试'), findsNWidgets(2));

    // E_CHALLENGE：打开该源的验证页，用户完成后自动重试该分组。
    final b = app.factory.created.singleWhere(
      (s) => s.manifest.id == 'com.example.b',
    );
    expect(b.searches, hasLength(1));
    await tester.tap(find.text('打开验证页'));
    await tester.pumpAndSettle();
    expect(app.verification.calls, ['com.example.b']);
    expect(b.searches, hasLength(2));

    await tester.tap(find.text('加载更多'));
    await tester.pumpAndSettle();
    expect(find.text('灯塔与猫'), findsOneWidget);
    expect(find.text('加载更多'), findsNothing);
    final a = app.factory.created.singleWhere(
      (s) => s.manifest.id == 'com.example.a',
    );
    expect(a.searches, [('星', 1), ('星', 2)]);

    await tester.tap(find.text('星之栖处'));
    await tester.pumpAndSettle();
    expect(
      app.router.state.uri.toString(),
      ComicRoutes.detail('com.example.a', '/comic/book/1'),
    );
    expect(a.details, ['/comic/book/1']);
    expect(find.text('虚构作者甲'), findsOneWidget);

    await app.dispose(tester);
  });

  testWidgets('没有已启用的源时提示导入', (tester) async {
    final app = AppHarness(FakeFactory(_build));
    await app.pump(tester);
    app.router.go('/search');
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '星');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.textContaining('没有已启用的漫画源'), findsOneWidget);
    await app.dispose(tester);
  });
}
