import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/features/comic/detail/comic_routes.dart';
import 'package:tsumugi/features/comic/reader/comic_reader_page.dart';
import 'package:tsumugi/sources/model/common.dart';
import 'package:tsumugi/sources/source.dart';

import '../../sources/runtime/runtime_support.dart';
import '../app_harness.dart';

/// 含 `/`、`?`、`&`、空格与中文的 id，验证路径编码。
const _itemId = '/comic/book/1?from=搜索&x=a b';

const _detail = Detail(
  id: _itemId,
  title: '星之栖处',
  author: '虚构作者甲',
  description: '一个关于在星星上搭建小屋的虚构故事。',
  tags: ['奇幻', '日常'],
  status: SeriesStatus.ongoing,
  cover: 'http://img.example.com/covers/1.png',
  groups: [
    UnitGroup(
      name: '线路一',
      units: [
        Unit(id: '/comic/book/1/chapter/1', title: '第 1 话'),
        Unit(id: '/comic/book/1/chapter/2', title: '第 2 话'),
        Unit(id: '/comic/book/1/chapter/3', title: '第 3 话'),
      ],
    ),
    UnitGroup(
      name: '线路二',
      units: [Unit(id: 'line2/1', title: '备用 第 1 话')],
    ),
  ],
);

double _y(WidgetTester tester, String text) =>
    tester.getTopLeft(find.text(text)).dy;

void main() {
  testWidgets('渲染详情；多线路切换；正序 / 倒序；点击章节跳转阅读器路径', (tester) async {
    final app = AppHarness(
      FakeFactory((m) => FakeSource(m, onDetail: (id) async => _detail)),
    );
    await app.install(tester, [fakeManifestJson('com.example.a')]);
    await app.pump(tester);
    app.router.push(ComicRoutes.detail('com.example.a', _itemId));
    await tester.pumpAndSettle();

    final source = app.factory.created.single;
    expect(source.details, [_itemId]);
    expect(find.text('星之栖处'), findsWidgets);
    expect(find.text('虚构作者甲'), findsOneWidget);
    expect(find.text('连载中'), findsOneWidget);
    expect(find.text('奇幻'), findsOneWidget);
    expect(find.text('日常'), findsOneWidget);
    expect(find.text('一个关于在星星上搭建小屋的虚构故事。'), findsOneWidget);
    // 没有阅读进度：显示“开始阅读”。
    expect(find.widgetWithText(FilledButton, '开始阅读'), findsOneWidget);
    expect(find.textContaining('上次读到'), findsNothing);

    expect(find.text('章节（3）'), findsOneWidget);
    expect(_y(tester, '第 1 话'), lessThan(_y(tester, '第 3 话')));
    await tester.tap(find.text('正序'));
    await tester.pumpAndSettle();
    expect(find.text('倒序'), findsOneWidget);
    expect(_y(tester, '第 3 话'), lessThan(_y(tester, '第 1 话')));

    await tester.tap(find.text('线路二'));
    await tester.pumpAndSettle();
    expect(find.text('章节（1）'), findsOneWidget);
    expect(find.text('第 1 话'), findsNothing);
    await tester.tap(find.text('线路一'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('第 2 话'));
    // 阅读器有持续的加载动画，不能 pumpAndSettle。
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
      app.router.state.uri.toString(),
      ComicRoutes.reader('com.example.a', _itemId, '/comic/book/1/chapter/2'),
    );
    // 阅读器拿到的是解码后的 id。
    final reader = tester.widget<ComicReaderPage>(find.byType(ComicReaderPage));
    expect(reader.sourceId, 'com.example.a');
    expect(reader.itemId, _itemId);
    expect(reader.unitId, '/comic/book/1/chapter/2');

    await app.dispose(tester);
  });

  testWidgets('没有 groups 时直接显示 units', (tester) async {
    final app = AppHarness(
      FakeFactory(
        (m) => FakeSource(
          m,
          onDetail: (id) async => Detail(
            id: id,
            title: '单线路',
            units: const [Unit(id: 'u1', title: '第 1 话')],
          ),
        ),
      ),
    );
    await app.install(tester, [fakeManifestJson('com.example.a')]);
    await app.pump(tester);
    app.router.push(ComicRoutes.detail('com.example.a', 'x'));
    await tester.pumpAndSettle();
    expect(find.text('章节（1）'), findsOneWidget);
    expect(find.byType(ChoiceChip), findsNothing);
    await app.dispose(tester);
  });

  testWidgets('加载失败显示错误与重试', (tester) async {
    var fail = true;
    final app = AppHarness(
      FakeFactory(
        (m) => FakeSource(
          m,
          onDetail: (id) => fail
              ? Future.error(
                  const SourceException(SourceErrorCode.http, null, 404),
                )
              : Future.value(Detail(id: id, title: '恢复了')),
        ),
      ),
    );
    await app.install(tester, [fakeManifestJson('com.example.a')]);
    await app.pump(tester);
    app.router.push(ComicRoutes.detail('com.example.a', 'x'));
    await tester.pumpAndSettle();
    expect(find.text('服务器返回错误（HTTP 404）'), findsOneWidget);

    fail = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('恢复了'), findsWidgets);
    await app.dispose(tester);
  });

  testWidgets('源未安装时提示', (tester) async {
    final app = AppHarness(FakeFactory());
    await app.pump(tester);
    app.router.push(ComicRoutes.detail('com.example.missing', 'x'));
    await tester.pumpAndSettle();
    expect(find.text('源未安装或已被删除'), findsOneWidget);
    await app.dispose(tester);
  });
}
