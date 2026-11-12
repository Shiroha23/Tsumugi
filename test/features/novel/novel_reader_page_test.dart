import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/features/novel/reader/novel_reader_page.dart';
import 'package:tsumugi/features/novel/reader/novel_reader_preferences.dart';
import 'package:tsumugi/features/novel/reader/novel_reader_providers.dart';
import 'package:tsumugi/sources/model/common.dart';
import 'package:tsumugi/sources/model/content.dart';
import 'package:tsumugi/sources/source.dart';

import '../../sources/runtime/runtime_support.dart';
import '../app_harness.dart';

const _sourceId = 'com.example.novel';
const _itemId = '/novel/book/1';

/// 第 i 段：`第i段` + 若干“字”，每段长度不同。
String _para(int i) => '第$i段${'字' * (30 + i % 5 * 9)}';

final _c1Text = [for (var i = 0; i < 60; i++) _para(i)].join('\n');

/// 第 [i] 段在 c1 中的起始偏移。
int _offsetOf(int i) {
  var offset = 0;
  for (var k = 0; k < i; k++) {
    offset += _para(k).length + 1;
  }
  return offset;
}

const _detail = Detail(
  id: _itemId,
  title: '青石巷的钟表匠',
  units: [
    Unit(id: 'c1', title: '第一章 倒走的怀表'),
    Unit(id: 'c2', title: '第二章 雨季'),
  ],
);

class _Reader {
  _Reader(this.app);

  final AppHarness app;
  final progress = <NovelReadingProgress>[];
  final fetched = <String>[];

  NovelReadingProgress get last => progress.last;
}

Future<_Reader> _open(
  WidgetTester tester, {
  NovelReaderPreferences prefs = const NovelReaderPreferences(),
  String unitId = 'c1',
  int position = 0,
}) async {
  late _Reader reader;
  final app = AppHarness(
    FakeFactory(
      (m) => FakeSource(
        m,
        onDetail: (_) async => _detail,
        onContent: (id) async {
          reader.fetched.add(id);
          return switch (id) {
            'c1' => NovelContent(text: _c1Text, nextPageId: 'c1?p=2'),
            'c1?p=2' => const NovelContent(
              text: '<p>分页后的<b>结尾</b>。</p>',
              html: true,
            ),
            _ => const NovelContent(text: '　　雨季来的时候。\n钟表铺。'),
          };
        },
      ),
    ),
    novelPreferences: MemoryNovelReaderPreferencesStore(prefs),
  );
  reader = _Reader(app);
  await app.install(tester, [
    fakeManifestJson(_sourceId, type: MediaType.novel),
  ]);
  tester.view.physicalSize = const Size(600, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: app.container,
      child: MaterialApp(
        home: NovelReaderPage(
          sourceId: _sourceId,
          itemId: _itemId,
          unitId: unitId,
          initialPosition: position,
          onProgress: reader.progress.add,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return reader;
}

Finder _text(String s) => find.textContaining(s, findRichText: true);

ScrollPosition _scroll(WidgetTester tester) => tester
    .state<ScrollableState>(
      find.descendant(
        of: find.byType(SingleChildScrollView),
        matching: find.byType(Scrollable),
      ),
    )
    .position;

Future<void> _key(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}

Future<void> _dispose(WidgetTester tester, AppHarness app) async {
  await tester.pumpWidget(const SizedBox());
  app.container.dispose();
  await tester.pumpAndSettle();
  await tester.runAsync(app.db.close);
}

void main() {
  testWidgets('滚动模式：拼接分页、段首缩进、上报进度；读到末尾后进入下一章', (tester) async {
    final r = await _open(tester);
    expect(r.fetched, ['c1', 'c1?p=2']);
    expect(_text('第一章 倒走的怀表'), findsOneWidget);
    expect(_text('　　第0段'), findsOneWidget);
    expect(_text('分页后的结尾。'), findsOneWidget);
    expect(r.last.unitId, 'c1');
    expect(r.last.unitTitle, '第一章 倒走的怀表');
    expect(r.last.position, 0);
    expect(r.last.atEnd, isFalse);
    expect(r.last.length, _c1Text.length + 1 + '分页后的结尾。'.length);

    // 键盘向下翻屏，位置前进。
    await _key(tester, LogicalKeyboardKey.pageDown);
    expect(_scroll(tester).pixels, greaterThan(0));
    final afterPage = r.last.position;
    expect(afterPage, greaterThan(0));

    await _key(tester, LogicalKeyboardKey.end);
    expect(r.last.atEnd, isTrue);
    expect(find.text('下一章：第二章 雨季'), findsOneWidget);

    // 到底后继续向下：进入下一章，从头开始。
    await _key(tester, LogicalKeyboardKey.arrowDown);
    expect(r.fetched.last, 'c2');
    expect(_text('雨季来的时候。'), findsOneWidget);
    expect(r.last.unitId, 'c2');
    expect(r.last.position, 0);

    // 回到顶部再向上：上一章，定位到末尾。
    await _key(tester, LogicalKeyboardKey.arrowUp);
    expect(r.last.unitId, 'c1');
    expect(r.last.atEnd, isTrue);
    await _dispose(tester, r.app);
  });

  testWidgets('滚动模式：打开时恢复到记录的字符偏移', (tester) async {
    final target = _offsetOf(30) + 5;
    final r = await _open(tester, position: target);
    expect(_scroll(tester).pixels, greaterThan(400));
    expect(r.progress.first.position, target);
    // 视口顶部就在第 30 段附近。
    final top = tester.getTopLeft(_text('第30段')).dy;
    expect(top, lessThan(100));
    expect(top, greaterThan(-200));
    await _dispose(tester, r.app);
  });

  testWidgets('翻页模式：按屏分页、键盘 / 点击翻页，进度为页首偏移', (tester) async {
    final r = await _open(
      tester,
      prefs: const NovelReaderPreferences(mode: NovelReaderMode.paged),
    );
    expect(find.byType(PageView), findsOneWidget);
    final footer = find.textContaining(RegExp(r'^1 / \d+$'));
    expect(footer, findsOneWidget);
    final total = int.parse(
      tester.widget<Text>(footer).data!.split(' / ').last,
    );
    expect(total, greaterThan(3));
    expect(r.last.position, 0);

    await _key(tester, LogicalKeyboardKey.arrowRight);
    expect(find.text('2 / $total'), findsOneWidget);
    final second = r.last.position;
    expect(second, greaterThan(0));
    // 第二页的第一个字符就是上报的偏移。
    expect(r.last.atEnd, isFalse);

    // 点击右侧三分之一翻到下一页，左侧翻回。
    await tester.tapAt(const Offset(560, 400));
    await tester.pumpAndSettle();
    expect(find.text('3 / $total'), findsOneWidget);
    await tester.tapAt(const Offset(40, 400));
    await tester.pumpAndSettle();
    expect(find.text('2 / $total'), findsOneWidget);
    expect(r.last.position, second);

    await _key(tester, LogicalKeyboardKey.end);
    expect(find.text('$total / $total'), findsOneWidget);
    expect(r.last.atEnd, isTrue);
    await _dispose(tester, r.app);
  });

  testWidgets('翻页模式：恢复位置；切换到滚动模式后位置不变；偏好被记住', (tester) async {
    final target = _offsetOf(40);
    final r = await _open(
      tester,
      prefs: const NovelReaderPreferences(mode: NovelReaderMode.paged),
      position: target,
    );
    expect(r.last.position, target);
    expect(find.textContaining(RegExp(r'^1 / ')), findsNothing);
    // 包含该偏移的页显示着第 40 段的开头。
    expect(_text('第40段'), findsOneWidget);

    // 中间点击呼出工具栏，打开阅读设置。
    await tester.tapAt(const Offset(300, 400));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('阅读设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('上下滚动'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('护眼'));
    await tester.pumpAndSettle();
    expect(r.app.novelPreferences.value.mode, NovelReaderMode.scroll);
    expect(r.app.novelPreferences.value.theme, NovelReaderTheme.sepia);

    // 关闭设置面板。
    await tester.tapAt(const Offset(300, 20));
    await tester.pumpAndSettle();
    expect(find.byType(PageView), findsNothing);
    expect(find.byType(SingleChildScrollView), findsOneWidget);
    expect(r.last.position, target);
    expect(_scroll(tester).pixels, greaterThan(400));
    await _dispose(tester, r.app);
  });

  testWidgets('改字号后重新分页，保持当前位置', (tester) async {
    final target = _offsetOf(25);
    final r = await _open(
      tester,
      prefs: const NovelReaderPreferences(mode: NovelReaderMode.paged),
      position: target,
    );
    final before = tester
        .widget<Text>(find.textContaining(RegExp(r'^\d+ / \d+$')))
        .data!;
    await r.app.container
        .read(novelReaderSettingsProvider.notifier)
        .change((p) => p.copyWith(fontSize: 30));
    await tester.pumpAndSettle();
    final after = tester
        .widget<Text>(find.textContaining(RegExp(r'^\d+ / \d+$')))
        .data!;
    expect(after, isNot(before));
    expect(
      int.parse(after.split(' / ').last),
      greaterThan(int.parse(before.split(' / ').last)),
    );
    expect(_text('第25段'), findsOneWidget);
    expect(r.app.novelPreferences.value.fontSize, 30);
    await _dispose(tester, r.app);
  });

  testWidgets('目录跳转', (tester) async {
    final r = await _open(tester);
    await tester.tapAt(const Offset(300, 400));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('目录'));
    await tester.pumpAndSettle();
    expect(find.text('目录（2）'), findsOneWidget);
    await tester.tap(find.text('第二章 雨季').last);
    await tester.pumpAndSettle();
    expect(r.fetched.last, 'c2');
    expect(r.last.unitId, 'c2');
    expect(_text('钟表铺。'), findsOneWidget);
    await _dispose(tester, r.app);
  });

  testWidgets('正文加载失败显示错误与重试', (tester) async {
    var fail = true;
    final app = AppHarness(
      FakeFactory(
        (m) => FakeSource(
          m,
          onDetail: (_) async => _detail,
          onContent: (_) => fail
              ? Future.error(
                  const SourceException(SourceErrorCode.http, null, 500),
                )
              : Future.value(const NovelContent(text: '恢复了')),
        ),
      ),
    );
    await app.install(tester, [
      fakeManifestJson(_sourceId, type: MediaType.novel),
    ]);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: app.container,
        child: const MaterialApp(
          home: NovelReaderPage(
            sourceId: _sourceId,
            itemId: _itemId,
            unitId: 'c1',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('服务器返回错误（HTTP 500）'), findsOneWidget);
    fail = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(_text('恢复了'), findsOneWidget);
    await _dispose(tester, app);
  });
}
