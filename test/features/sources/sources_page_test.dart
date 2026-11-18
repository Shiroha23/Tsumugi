import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/network/session_persistence.dart';
import 'package:tsumugi/core/network/source_session.dart';
import 'package:tsumugi/core/storage/app_database.dart';
import 'package:tsumugi/features/sources/manifest_file_picker.dart';
import 'package:tsumugi/features/sources/sources_page.dart';
import 'package:tsumugi/shared/webview/providers.dart';
import 'package:tsumugi/sources/registry/providers.dart';
import 'package:tsumugi/sources/repository/providers.dart';
import 'package:tsumugi/sources/session/source_sessions.dart';
import 'package:tsumugi/sources/source.dart';

import '../../core/storage/test_database.dart';
import '../../shared/webview/webview_fakes.dart';

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
  late FakeSourceVerification verification;

  setUp(() {
    db = openTestDatabase();
    registry = SourceRegistry(db);
    picker = _FakePicker();
    verification = FakeSourceVerification();
  });
  tearDown(() => db.close());

  Future<void> pumpPage(
    WidgetTester tester, {
    SessionPersistence? persistence,
  }) async {
    tester.view.physicalSize = const Size(800, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          sessionPersistenceProvider.overrideWithValue(persistence),
          manifestFilePickerProvider.overrideWithValue(picker),
          sourceVerificationProvider.overrideWithValue(verification),
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

  Future<void> openMenuItem(WidgetTester tester, String item) async {
    await tester.tap(find.byTooltip('源菜单'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(item).last);
    await tester.pumpAndSettle();
  }

  testWidgets('源菜单清除该源的 Cookie 与登录状态（需要确认）', (tester) async {
    await registry.importText(fixture('declarative_comic.json'));
    await pumpPage(tester);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SourcesPage)),
    );
    final session = container
        .read(sourceSessionsProvider)
        .of('com.example.comic');
    final site = Uri.parse('https://example.com/');
    await tester.runAsync(() async {
      await session.cookieJar.saveFromResponse(site, [Cookie('session', 'ok')]);
    });
    session.userAgent = 'UA';

    await openMenuItem(tester, '清除 Cookie 与登录状态');
    expect(find.textContaining('确定清除「示例漫画」'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(session.userAgent, 'UA');

    await openMenuItem(tester, '清除 Cookie 与登录状态');
    await tester.tap(find.widgetWithText(FilledButton, '清除'));
    await tester.pumpAndSettle();
    expect(find.text('已清除「示例漫画」的 Cookie 与登录状态'), findsOneWidget);
    expect(session.userAgent, isNull);
    final left = await tester.runAsync(
      () => session.cookieJar.loadForRequest(site),
    );
    expect(left, isEmpty);
    // 源仍然安装着。
    expect(await registry.get('com.example.comic'), isNotNull);
    await unmount(tester);
  });

  testWidgets('删除源时立即删除其 Cookie 文件（会话管理器此前未创建也一样）', (tester) async {
    const id = 'com.example.comic';
    await registry.importText(fixture('declarative_comic.json'));
    final dir = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('tsumugi_sessions_'),
    ))!;
    addTearDown(() => dir.deleteSync(recursive: true));
    final persistence = SessionPersistence.at(dir);
    final file = File('${dir.path}/${SessionPersistence.fileNameFor(id)}');
    // 上次运行登录留下的会话文件。
    await tester.runAsync(() async {
      final previous = SourceSession.persistent(id, SessionPersistence.at(dir));
      await previous.cookieJar.saveFromResponse(
        Uri.parse('https://example.com/'),
        [Cookie('session', 'ok')],
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    expect(file.existsSync(), isTrue);

    await pumpPage(tester, persistence: persistence);
    await openMenuItem(tester, '删除');
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    // 删除在 fake async 区域中排队：交替让真实 IO 完成并推进 fake 时间。
    for (var i = 0; i < 50 && file.existsSync(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(file.existsSync(), isFalse);
    await unmount(tester);
  });

  testWidgets('删除需要确认', (tester) async {
    await registry.importText(fixture('declarative_comic.json'));
    await pumpPage(tester);

    await openMenuItem(tester, '删除');
    expect(find.text('确定删除「示例漫画」吗？此操作不可撤销。'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('示例漫画'), findsOneWidget);

    await openMenuItem(tester, '删除');
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

  group('源设置（#58）', () {
    String settingsFixture() => fixture('settings_comic.json');

    testWidgets('没有可显示设置的源不显示「源设置」', (tester) async {
      await registry.importText(comicWith({'settings': []}));
      await pumpPage(tester);
      await tester.tap(find.byTooltip('源菜单'));
      await tester.pumpAndSettle();
      expect(find.text('源设置'), findsNothing);
      expect(find.text('登录 / 打开网页'), findsOneWidget);
      await tester.tapAt(Offset.zero);
      await tester.pumpAndSettle();
      await unmount(tester);
    });

    testWidgets('只有未知类型的设置时同样不显示', (tester) async {
      await registry.importText(
        comicWith({
          'settings': [
            {'key': 'f', 'label': '将来', 'type': 'slider'},
          ],
        }),
      );
      await pumpPage(tester);
      await tester.tap(find.byTooltip('源菜单'));
      await tester.pumpAndSettle();
      expect(find.text('源设置'), findsNothing);
      await tester.tapAt(Offset.zero);
      await tester.pumpAndSettle();
      await unmount(tester);
    });

    testWidgets('文本超长（按 UTF-16 码元）时提示错误、不关闭、不保存', (tester) async {
      final s = await registry.importText(settingsFixture());
      await pumpPage(tester);
      await openMenuItem(tester, '源设置');
      await tester.enterText(find.byType(TextField), '😀' * 513);
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.textContaining('最长 1024 个字符'), findsOneWidget);
      expect((await registry.get(s.id))!.storedSettings, isEmpty);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await unmount(tester);
    });

    testWidgets('源在对话框打开期间被删除：提示未保存', (tester) async {
      final s = await registry.importText(settingsFixture());
      await pumpPage(tester);
      await openMenuItem(tester, '源设置');
      await registry.remove(s.id);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();
      expect(find.text('源不可用，设置未保存'), findsOneWidget);
      expect(find.textContaining('已保存「'), findsNothing);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await unmount(tester);
    });

    testWidgets('按清单渲染并保存；取消不保存', (tester) async {
      final s = await registry.importText(settingsFixture());
      await pumpPage(tester);

      await openMenuItem(tester, '源设置');
      expect(find.text('源设置 · 设置示例'), findsOneWidget);
      expect(find.text('画质'), findsOneWidget);
      expect(find.text('mid'), findsOneWidget); // 清单默认值
      expect(find.text('高清封面'), findsOneWidget);
      expect(find.text('镜像路径'), findsOneWidget);
      expect(find.text('将来的类型'), findsNothing); // 未知类型不显示
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isTrue,
      );

      // 取消：不写库。
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect((await registry.get(s.id))!.storedSettings, isEmpty);

      await openMenuItem(tester, '源设置');
      await tester.tap(find.text('mid'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('low').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '/m\nirror');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('已保存「设置示例」的设置，下一次请求时生效'), findsOneWidget);
      final saved = (await registry.get(s.id))!;
      expect(saved.storedSettings, {
        'quality': 'low',
        'hd': false,
        'mirror': '/mirror', // 换行被过滤
      });

      // 再次打开显示已保存的值；恢复默认后保存清空。
      await openMenuItem(tester, '源设置');
      expect(find.text('low'), findsOneWidget);
      expect(find.text('/mirror'), findsOneWidget);
      await tester.tap(find.text('恢复默认'));
      await tester.pumpAndSettle();
      expect(find.text('mid'), findsOneWidget);
      expect(find.text('/mirror'), findsNothing);
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();
      expect((await registry.get(s.id))!.storedSettings, isEmpty);
      await unmount(tester);
    });
  });

  group('登录 / 打开网页（#59）', () {
    testWidgets('调用验证流程打开登录页；完成后提示', (tester) async {
      await registry.importText(fixture('declarative_comic.json'));
      await pumpPage(tester);

      await openMenuItem(tester, '登录 / 打开网页');
      expect(verification.loginCalls, ['com.example.comic']);
      expect(verification.calls, isEmpty, reason: '不走「打开验证页」的地址选择');
      expect(find.text('已保存「示例漫画」的 Cookie 与登录状态'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('用户取消时不提示', (tester) async {
      verification.result = false;
      await registry.importText(fixture('declarative_comic.json'));
      await pumpPage(tester);
      await openMenuItem(tester, '登录 / 打开网页');
      expect(verification.loginCalls, hasLength(1));
      expect(find.byType(SnackBar), findsNothing);
      await unmount(tester);
    });

    testWidgets('失败时提示原因', (tester) async {
      verification.error = const SourceException(
        SourceErrorCode.unsupported,
        '当前平台不支持 WebView',
      );
      await registry.importText(fixture('declarative_comic.json'));
      await pumpPage(tester);
      await openMenuItem(tester, '登录 / 打开网页');
      expect(find.textContaining('无法打开登录页'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('清单不可用的源不显示登录与设置', (tester) async {
      await registry.importText(fixture('declarative_comic.json'));
      await db.customStatement(
        "UPDATE installed_sources SET manifest_json = '{oops'",
      );
      await pumpPage(tester);
      await tester.tap(find.byTooltip('源菜单'));
      await tester.pumpAndSettle();
      expect(find.text('登录 / 打开网页'), findsNothing);
      expect(find.text('源设置'), findsNothing);
      expect(find.text('删除'), findsOneWidget);
      await tester.tapAt(Offset.zero);
      await tester.pumpAndSettle();
      await unmount(tester);
    });
  });

  group('规则仓库状态', () {
    const repoUrl = 'https://repo.example.com/repo/live/index.json';

    Future<RepositoryService> setUpRepository(String published) async {
      final service = RepositoryService(db, registry, RepositoryHttpClient());
      // 已安装 flow-v1；仓库索引为 [published]。
      await registry.install(
        await registry.prepareImportBytes(
          File('test/fixtures/repository/flow-v1/sources/flow.json')
              .readAsBytesSync(),
          origin: const SourceOrigin.repository(
            'https://repo.example.com/repo/live/sources/flow.json',
            repositoryUrl: repoUrl,
          ),
        ),
      );
      await service.subscribe(
        parseRepositoryIndex(
          File('test/fixtures/repository/$published/index.json')
              .readAsBytesSync(),
          Uri.parse(repoUrl),
        ),
      );
      return service;
    }

    testWidgets('仓库有更高版本：标“可更新”，入口显示数量，菜单有「更新」', (tester) async {
      await setUpRepository('flow-v2');
      await pumpPage(tester);
      expect(find.textContaining('可更新到 1.1.0'), findsOneWidget);
      expect(
        find.descendant(of: find.byTooltip('规则仓库'), matching: find.text('1')),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('源菜单'));
      await tester.pumpAndSettle();
      expect(find.text('更新'), findsOneWidget);
      await tester.tapAt(Offset.zero);
      await tester.pumpAndSettle();
      expect(
        (await registry.get('com.example.repo.flow'))!.version,
        '1.0.0',
        reason: '只提示，不自动安装',
      );
      await unmount(tester);
    });

    testWidgets('退订后显示“仓库已移除”', (tester) async {
      final service = await setUpRepository('flow-v1');
      await pumpPage(tester);
      expect(find.textContaining('可更新'), findsNothing);
      expect(find.textContaining('仓库已移除'), findsNothing);
      await service.unsubscribe(repoUrl);
      await tester.pumpAndSettle();
      expect(find.textContaining('仓库已移除'), findsOneWidget);
      await tester.tap(find.byTooltip('源菜单'));
      await tester.pumpAndSettle();
      expect(find.text('更新'), findsNothing);
      await tester.tapAt(Offset.zero);
      await tester.pumpAndSettle();
      await unmount(tester);
    });
  });
}
