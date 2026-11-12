import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/storage/app_database.dart';
import 'package:tsumugi/features/sources/manifest_file_picker.dart';
import 'package:tsumugi/features/sources/sources_page.dart';
import 'package:tsumugi/sources/registry/providers.dart';

import '../../core/storage/test_database.dart';

String fixture(String name) =>
    File('test/fixtures/sources/$name').readAsStringSync();

String comicWith(Map<String, Object?> changes) => jsonEncode({
  ...jsonDecode(fixture('declarative_comic.json')) as Map,
  ...changes,
});

class _FakePicker implements ManifestFilePicker {
  PickedManifestFile? next;

  @override
  Future<PickedManifestFile?> pick() async => next;
}

void main() {
  late AppDatabase db;
  late SourceRegistry registry;
  late _FakePicker picker;

  setUp(() {
    db = openTestDatabase();
    registry = SourceRegistry(db);
    picker = _FakePicker();
  });
  tearDown(() => db.close());

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          manifestFilePickerProvider.overrideWithValue(picker),
        ],
        child: const MaterialApp(home: SourcesPage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openImportDialog(WidgetTester tester) async {
    await tester.tap(find.byTooltip('导入源'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
  }

  /// 卸载页面，让 drift 的 stream 在测试结束前关闭。
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  }

  testWidgets('没有源时显示空状态与导入按钮', (tester) async {
    await pumpPage(tester);
    expect(find.text('还没有安装任何源'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '导入源'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('粘贴 JSON → 预览名称、类型、版本、主机 → 安装后出现在列表', (tester) async {
    await pumpPage(tester);
    await openImportDialog(tester);

    await tester.enterText(
      find.byType(TextField),
      fixture('declarative_comic.json'),
    );
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();

    final dialog = find.byType(AlertDialog);
    Finder inDialog(String text) =>
        find.descendant(of: dialog, matching: find.text(text));
    expect(inDialog('安装源'), findsOneWidget);
    expect(inDialog('示例漫画'), findsOneWidget);
    expect(inDialog('漫画'), findsOneWidget);
    expect(inDialog('1.0.0'), findsOneWidget);
    expect(inDialog('声明式'), findsOneWidget);
    expect(inDialog('example.com'), findsOneWidget);
    expect(inDialog('*.example-cdn.com'), findsOneWidget);
    expect(
      find.descendant(
        of: dialog,
        matching: find.textContaining('someFutureField'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(FilledButton, '安装'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('已安装「示例漫画」'), findsOneWidget);
    expect(find.text('漫画（1）'), findsOneWidget);
    expect(find.text('示例漫画'), findsOneWidget);
    expect(find.textContaining('v1.0.0 · 声明式 · example.com'), findsOneWidget);
    expect((await registry.getAll()).single.id, 'com.example.comic');
    await unmount(tester);
  });

  testWidgets('非法 JSON 显示错误并停留在输入步骤', (tester) async {
    await pumpPage(tester);
    await openImportDialog(tester);

    await tester.enterText(find.byType(TextField), '{"id": ');
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();

    expect(find.textContaining('JSON 格式错误'), findsOneWidget);
    expect(find.text('下一步'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    await unmount(tester);
  });

  testWidgets('不支持的 apiVersion 给出明确提示', (tester) async {
    await pumpPage(tester);
    await openImportDialog(tester);

    await tester.enterText(
      find.byType(TextField),
      fixture('future_api_version.json'),
    );
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(find.textContaining('需要更新版本的客户端'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('选择文件导入，按类型分组', (tester) async {
    await registry.importText(fixture('declarative_comic.json'));
    await pumpPage(tester);
    await openImportDialog(tester);

    picker.next = (
      name: 'script_novel.json',
      bytes: Uint8List.fromList(utf8.encode(fixture('script_novel.json'))),
    );
    await tester.tap(find.text('选择文件'));
    await tester.pumpAndSettle();

    expect(find.text('示例小说'), findsOneWidget);
    expect(find.text('NSFW'), findsOneWidget);
    expect(find.text('novel.example.com'), findsOneWidget);
    expect(find.text('api.example.com'), findsOneWidget);
    expect(find.text('*.img.example.com'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '安装'));
    await tester.pumpAndSettle();

    expect(find.text('漫画（1）'), findsOneWidget);
    expect(find.text('小说（1）'), findsOneWidget);
    final s = await registry.get('com.example.novel');
    expect(s!.origin.label, 'script_novel.json');
    await unmount(tester);
  });

  testWidgets('从剪贴板导入；更新时显示版本变化', (tester) async {
    await registry.importText(fixture('declarative_comic.json'));
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => call.method == 'Clipboard.getData'
          ? {
              'text': comicWith({'version': '1.2.0'}),
            }
          : null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await pumpPage(tester);
    await openImportDialog(tester);
    await tester.tap(find.text('从剪贴板粘贴'));
    await tester.pumpAndSettle();

    expect(find.text('更新源'), findsOneWidget);
    expect(find.text('1.0.0 → 1.2.0'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '更新'));
    await tester.pumpAndSettle();

    expect(find.textContaining('v1.2.0'), findsOneWidget);
    expect((await registry.get('com.example.comic'))!.version, '1.2.0');
    await unmount(tester);
  });

  testWidgets('降级被拒绝', (tester) async {
    await registry.importText(comicWith({'version': '2.0.0'}));
    await pumpPage(tester);
    await openImportDialog(tester);

    await tester.enterText(
      find.byType(TextField),
      fixture('declarative_comic.json'),
    );
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();

    expect(find.textContaining('不能降级'), findsOneWidget);
    expect(find.text('安装'), findsNothing);
    await unmount(tester);
  });

  testWidgets('开关启用状态', (tester) async {
    await registry.importText(fixture('declarative_comic.json'));
    await pumpPage(tester);

    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    expect((await registry.get('com.example.comic'))!.enabled, isFalse);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect((await registry.get('com.example.comic'))!.enabled, isTrue);
    await unmount(tester);
  });

  testWidgets('删除需要确认', (tester) async {
    await registry.importText(fixture('declarative_comic.json'));
    await pumpPage(tester);

    await tester.tap(find.byTooltip('删除'));
    await tester.pumpAndSettle();
    expect(find.text('确定删除「示例漫画」吗？此操作不可撤销。'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('示例漫画'), findsOneWidget);

    await tester.tap(find.byTooltip('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(find.text('还没有安装任何源'), findsOneWidget);
    expect(await registry.getAll(), isEmpty);
    await unmount(tester);
  });

  testWidgets('拖动排序', (tester) async {
    await registry.importText(fixture('declarative_comic.json'));
    await registry.importText(
      comicWith({'id': 'com.example.comic2', 'name': '漫画二'}),
    );
    await registry.importText(
      comicWith({'id': 'com.example.comic3', 'name': '漫画三'}),
    );
    await pumpPage(tester);

    final handle = find.byIcon(Icons.drag_handle).first;
    final tileHeight = tester.getSize(find.byType(ListTile).first).height;
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(Offset(0, tileHeight * 2.2 / 10));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect((await registry.getAll()).map((s) => s.id), [
      'com.example.comic2',
      'com.example.comic3',
      'com.example.comic',
    ]);
    final titles = tester
        .widgetList<ListTile>(find.byType(ListTile))
        .map((t) => (t.title as Text).data)
        .toList();
    expect(titles, ['漫画二', '漫画三', '示例漫画']);
    await unmount(tester);
  });
}
