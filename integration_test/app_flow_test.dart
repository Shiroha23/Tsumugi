// #32：完整应用（真实路由、真实声明式 / 脚本引擎、真实图片加载器）在设备上跑通主要流程：
//
// 1. 加载 JS 脚本源（QuickJS 原生库）→ 搜索 → 详情 → 漫画阅读器翻页；
// 2. 小说阅读器（翻页模式）翻页，读到末尾进入下一章；
// 3. 导出 TXT 与 EPUB：系统保存界面无法自动操作，用 [_FileExportSaver] 写入临时目录，再校验文件内容。
//
// 所有请求都经自定义连接接到 mock 服务器（虚构主机名，见 test_mock.dart），白名单仍按虚构主机名检查。
// 运行方式见 docs/architecture.md §5.4「设备与模拟器上的集成测试」：
//
//   Windows（mock 服务器在测试进程内启动）：
//     flutter test integration_test/app_flow_test.dart -d windows
//
//   Android 模拟器 / 真机、iOS 模拟器（先在电脑上以 --test-control 启动 mock 服务器）：
//     dart run tool/mock_server/main.dart --port 8081 --test-control
//     adb reverse tcp:8081 tcp:8081          # 仅 Android；iOS 模拟器与电脑共用网络
//     flutter test integration_test/app_flow_test.dart -d <设备> \
//       --dart-define=TSUMUGI_MOCK_SERVER=127.0.0.1:8081

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tsumugi/app/router.dart';
import 'package:tsumugi/core/network/dio_source_http_client.dart';
import 'package:tsumugi/core/storage/app_database.dart';
import 'package:tsumugi/features/comic/reader/reader_preferences.dart';
import 'package:tsumugi/features/explore/explore_preferences.dart';
import 'package:tsumugi/features/novel/novel_routes.dart';
import 'package:tsumugi/features/novel/reader/novel_reader_preferences.dart';
import 'package:tsumugi/shared/export/providers.dart';
import 'package:tsumugi/shared/image/image_cache.dart';
import 'package:tsumugi/shared/image/image_providers.dart';
import 'package:tsumugi/sources/network_error_mapping.dart';
import 'package:tsumugi/sources/registry/providers.dart';
import 'package:tsumugi/sources/session/source_sessions.dart';
import 'package:xml/xml.dart';

import '../test/core/storage/test_database.dart';
import '../test/sources/runtime/runtime_support.dart';
import 'test_mock.dart';

const _novelId = 'com.example.mock.novel.declarative';
const _novelItem = '/novel/book/1';

/// 测试用的保存实现：写入临时目录，记录保存的文件。
class _FileExportSaver implements ExportSaver {
  _FileExportSaver(this.dir);

  final Directory dir;
  final saved = <File>[];

  @override
  Future<String?> save(ExportFile file) async {
    final out = File('${dir.path}${Platform.pathSeparator}${file.fileName}');
    await out.writeAsBytes(file.bytes, flush: true);
    saved.add(out);
    return out.path;
  }
}

/// 完整应用：真实路由与引擎，HTTP 连接接到 mock 服务器，存储都在内存中。
class _App {
  _App(this.server, this.saver, {NovelReaderPreferences? novel})
    : novelPreferences = MemoryNovelReaderPreferencesStore(
        novel ?? const NovelReaderPreferences(),
      );

  final TestMock server;
  final _FileExportSaver saver;
  final MemoryNovelReaderPreferencesStore novelPreferences;
  final AppDatabase db = openTestDatabase();
  late final registry = SourceRegistry(db);

  late final ProviderContainer container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      sessionPersistenceProvider.overrideWithValue(null),
      // 与应用一样，源实例与图片加载共用该源的会话。
      sourceFactoriesProvider.overrideWith(
        (ref) => adapterFactories(
          server.adapter,
          session: ref.read(sourceSessionsProvider).of,
        ),
      ),
      imageHttpClientsProvider.overrideWith((ref) {
        final clients = RegistryImageHttpClients(
          ref.watch(sourceRegistryProvider),
          clientFor: (m) => DioSourceHttpClient(
            networkConfigFromManifest(m),
            adapter: server.adapter(),
            session: ref.read(sourceSessionsProvider).of(m.id),
          ),
        );
        ref.onDispose(clients.dispose);
        return clients;
      }),
      diskImageCacheProvider.overrideWithValue(const NoDiskImageCache()),
      readerPreferencesStoreProvider.overrideWithValue(
        MemoryReaderPreferencesStore(
          // 横向翻页：点击左 / 右三分之一翻页。
          const ReaderPreferences(mode: ReaderMode.leftToRight),
        ),
      ),
      novelReaderPreferencesStoreProvider.overrideWithValue(novelPreferences),
      explorePreferencesStoreProvider.overrideWithValue(
        MemoryExplorePreferencesStore(),
      ),
      exportSaverProvider.overrideWithValue(saver),
    ],
  );

  Future<void> install(WidgetTester tester, List<String> manifests) async {
    await tester.runAsync(() async {
      for (final m in manifests) {
        await registry.importText(m);
      }
    });
  }

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: Consumer(
          builder: (context, ref, _) =>
              MaterialApp.router(routerConfig: ref.watch(routerProvider)),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    await tester.pump(const Duration(milliseconds: 100));
    await db.close();
  }
}

/// 真实网络与原生代码，不能用 pumpAndSettle（加载动画、图片解码），逐帧等到条件满足。
Future<void> _pumpUntil(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final end = DateTime.now().add(timeout);
  while (finder.evaluate().isEmpty) {
    if (DateTime.now().isAfter(end)) fail('超时：$finder');
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// 等到 [finder] 消失（如对话框的退出动画结束）。
Future<void> _pumpUntilGone(WidgetTester tester, Finder finder) async {
  final end = DateTime.now().add(const Duration(seconds: 10));
  while (finder.evaluate().isNotEmpty) {
    if (DateTime.now().isAfter(end)) fail('超时：仍有 $finder');
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _tapAndWait(
  WidgetTester tester,
  Finder target,
  Finder expected,
) async {
  await tester.tap(target);
  await tester.pump();
  await _pumpUntil(tester, expected);
}

/// 点击屏幕横向 [fraction] 处（阅读器的翻页区），等双击判定结束。
Future<void> _tapZone(WidgetTester tester, double fraction) async {
  final size = tester.view.physicalSize / tester.view.devicePixelRatio;
  await tester.tapAt(Offset(size.width * fraction, size.height / 2));
  await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 400));
}

/// 清单的 `script` 换成 test/fixtures/script/ 下的源文件（与单元测试一致）。
Future<String> _scriptManifest(
  TestMock server,
  String manifest,
  String script,
) async => jsonEncode({
  ...jsonDecode(await server.fixture(manifest)) as Map<String, dynamic>,
  'script': await server.fixture(script),
});

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late TestMock server;
  late _FileExportSaver saver;

  setUp(() async {
    server = await TestMock.start();
    final tmp = await getTemporaryDirectory();
    saver = _FileExportSaver(await tmp.createTemp('tsumugi_export_'));
  });
  tearDown(() async {
    await server.close();
    await saver.dir.delete(recursive: true);
  });

  testWidgets('脚本源：搜索 → 详情 → 漫画阅读器翻页', (tester) async {
    final app = _App(server, saver);
    await app.install(tester, [
      await _scriptManifest(
        server,
        'sources/mock_comic_script.json',
        'script/comic/source.js',
      ),
    ]);
    await app.pump(tester);

    app.container.read(routerProvider).go('/search');
    await _pumpUntil(tester, find.byType(TextField));
    await tester.enterText(find.byType(TextField), '星');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await _pumpUntil(tester, find.text('星之栖处'));
    expect(find.text('Mock 漫画（脚本）'), findsOneWidget);
    expect(find.text('雨夜纸鹤'), findsOneWidget);

    // 详情：脚本把倒序的章节列表反转。
    await _tapAndWait(tester, find.text('星之栖处'), find.text('虚构作者甲'));
    await _pumpUntil(tester, find.text('第 1 话 落脚点'));
    expect(find.text('第 3 话 流星雨'), findsOneWidget);

    // 阅读器：3 页，点击右 / 左三分之一翻页。
    await _tapAndWait(tester, find.text('第 1 话 落脚点'), find.text('1 / 3'));
    await _tapZone(tester, 0.9);
    await _pumpUntil(tester, find.text('2 / 3'));
    await _tapZone(tester, 0.9);
    await _pumpUntil(tester, find.text('3 / 3'));
    await _tapZone(tester, 0.1);
    await _pumpUntil(tester, find.text('2 / 3'));

    final requests = await server.requests();
    final paths = requests.map((r) => '${r.host}${r.path}').toSet();
    expect(
      paths,
      containsAll([
        '127.0.0.1/comic/search',
        '127.0.0.1/comic/book/1',
        '127.0.0.1/comic/book/1/chapter/1',
        // 漫画页经源的图片客户端加载（虚构图片主机、脚本给出的请求头）。
        'img.example.com/pages/1/1/001.png',
        'img.example.com/pages/1/1/002.png',
      ]),
    );
    expect(
      requests
          .where((r) => r.path.startsWith('/pages/'))
          .map((r) => r.headers['x-quality'])
          .toSet(),
      {'high'},
    );
    await app.dispose(tester);
  });

  testWidgets('小说阅读器：翻页模式翻到末尾进入下一章', (tester) async {
    final app = _App(
      server,
      saver,
      novel: const NovelReaderPreferences(mode: NovelReaderMode.paged),
    );
    await app.install(tester, [
      await server.fixture('sources/mock_novel_declarative.json'),
    ]);
    await app.pump(tester);
    app.container
        .read(routerProvider)
        .push(NovelRoutes.detail(_novelId, _novelItem));
    await _pumpUntil(tester, find.text('第一章 倒走的怀表'));
    await _tapAndWait(
      tester,
      find.text('第一章 倒走的怀表'),
      find.textContaining(RegExp(r'^1 / \d+$')),
    );
    // 章节内分页（?p=2）已拼接。
    expect(find.textContaining('一位客人送来一只怀表', findRichText: true), findsWidgets);

    // 逐页向后翻，直到进入第二章（每章的页数取决于屏幕大小）。
    final chapter2 = find.textContaining('雨季来的时候', findRichText: true);
    for (var i = 0; chapter2.evaluate().isEmpty; i++) {
      if (i > 20) fail('翻页 20 次仍未进入第二章');
      await _tapZone(tester, 0.9);
    }
    await _pumpUntil(tester, find.textContaining(RegExp(r'^1 / \d+$')));
    // 向前翻回到第一章的最后一页。
    await _tapZone(tester, 0.1);
    await _pumpUntil(
      tester,
      find.textContaining('一位客人送来一只怀表', findRichText: true),
    );
    await app.dispose(tester);
  });

  testWidgets('导出 TXT 与 EPUB', (tester) async {
    final app = _App(server, saver);
    await app.install(tester, [
      await server.fixture('sources/mock_novel_declarative.json'),
    ]);
    await app.pump(tester);
    app.container
        .read(routerProvider)
        .push(NovelRoutes.detail(_novelId, _novelItem));
    await _pumpUntil(tester, find.widgetWithText(OutlinedButton, '导出'));

    Future<File> export({required bool txt}) async {
      await _tapAndWait(
        tester,
        find.widgetWithText(OutlinedButton, '导出'),
        find.text('导出小说'),
      );
      if (txt) {
        await tester.tap(find.text('TXT'));
        await tester.pump();
      }
      await _tapAndWait(
        tester,
        find.text('开始导出'),
        find.textContaining('已导出 2 / 2 章'),
      );
      await _tapAndWait(
        tester,
        find.text('保存文件'),
        find.textContaining('已保存到：'),
      );
      await tester.tap(find.text('关闭'));
      await _pumpUntilGone(tester, find.text('导出小说'));
      return saver.saved.last;
    }

    final txt = await export(txt: true);
    expect(txt.path, endsWith('青石巷的钟表匠.txt'));
    final text = utf8.decode(await txt.readAsBytes());
    expect(text, contains('来源：Mock 小说（声明式）'));
    expect(text, contains('第一章 倒走的怀表'));
    // 章节内分页的两页都在。
    expect(text, contains('一位客人送来一只怀表'));
    expect(text, contains('第二章 雨季'));
    expect(text, contains('雨季来的时候'));

    final epub = await export(txt: false);
    expect(epub.path, endsWith('青石巷的钟表匠.epub'));
    final archive = ZipDecoder().decodeBytes(await epub.readAsBytes());
    String entry(String name) => utf8.decode(archive.findFile(name)!.content);
    expect(archive.files.first.name, 'mimetype');
    expect(entry('mimetype'), 'application/epub+zip');
    final opf = XmlDocument.parse(entry('OEBPS/content.opf'));
    expect(opf.findAllElements('dc:title').single.innerText, '青石巷的钟表匠');
    expect(opf.findAllElements('dc:creator').single.innerText, '虚构作者丁');
    final chapters = [
      for (final f in archive.files)
        if (RegExp(r'^OEBPS/chapter-\d+\.xhtml$').hasMatch(f.name))
          entry(f.name),
    ];
    expect(chapters, hasLength(2));
    expect(chapters.join(), contains('一位客人送来一只怀表'));
    expect(chapters.join(), contains('雨季来的时候'));
    await app.dispose(tester);
  });
}
