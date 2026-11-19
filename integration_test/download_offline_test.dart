// M6 下载管理第一期（docs/architecture.md §4.5）：完整应用（真实路由、脚本引擎、图片加载器、下载队列与磁盘文件）
//
// 1. 详情页「下载」漫画章节（脚本源，带请求头的虚构图片主机）与带插图的小说章节；
// 2. mock 服务器断网（之后的连接都被直接断开）；
// 3. 从书架「下载」标签进入条目，打开已下载的章节：漫画页、小说正文与插图都从本地文件读取，目录来自下载时的快照。
//
// 运行方式同 app_flow_test.dart（docs/architecture.md §5.4「设备与模拟器上的集成测试」）：
//
//   Windows：flutter test integration_test/download_offline_test.dart -d windows
//
//   Android / iOS 模拟器（先在电脑上以 --test-control 启动 mock 服务器）：
//     dart run tool/mock_server/main.dart --port 8081 --test-control
//     adb reverse tcp:8081 tcp:8081          # 仅 Android
//     flutter test integration_test/download_offline_test.dart -d <设备> \
//       --dart-define=TSUMUGI_MOCK_SERVER=127.0.0.1:8081

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tsumugi/app/router.dart';
import 'package:tsumugi/core/network/dio_source_http_client.dart';
import 'package:tsumugi/core/storage/app_database.dart';
import 'package:tsumugi/features/comic/detail/comic_routes.dart';
import 'package:tsumugi/features/comic/reader/reader_preferences.dart';
import 'package:tsumugi/features/explore/explore_preferences.dart';
import 'package:tsumugi/features/novel/novel_routes.dart';
import 'package:tsumugi/features/novel/reader/novel_reader_preferences.dart';
import 'package:tsumugi/shared/download/providers.dart';
import 'package:tsumugi/shared/image/image_cache.dart';
import 'package:tsumugi/shared/image/image_providers.dart';
import 'package:tsumugi/sources/network_error_mapping.dart';
import 'package:tsumugi/sources/registry/providers.dart';
import 'package:tsumugi/sources/session/source_sessions.dart';

import '../test/core/storage/test_database.dart';
import '../test/sources/runtime/runtime_support.dart';
import 'test_mock.dart';

const _comicId = 'com.example.mock.comic.script';
const _comicItem = '/comic/book/1';
const _novelId = 'com.example.mock.novel.script';
const _novelItem = '/novel/book/1';

class _App {
  _App(this.server, this.downloads);

  final TestMock server;
  final Directory downloads;
  final AppDatabase db = openTestDatabase();
  late final registry = SourceRegistry(db);

  late final ProviderContainer container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      sessionPersistenceProvider.overrideWithValue(null),
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
      // 不用磁盘缓存：离线时的图片只可能来自下载目录。
      diskImageCacheProvider.overrideWithValue(const NoDiskImageCache()),
      downloadStoreProvider.overrideWithValue(DownloadStore(() => downloads)),
      readerPreferencesStoreProvider.overrideWithValue(
        MemoryReaderPreferencesStore(
          const ReaderPreferences(mode: ReaderMode.leftToRight),
        ),
      ),
      novelReaderPreferencesStoreProvider.overrideWithValue(
        MemoryNovelReaderPreferencesStore(const NovelReaderPreferences()),
      ),
      explorePreferencesStoreProvider.overrideWithValue(
        MemoryExplorePreferencesStore(),
      ),
    ],
  );

  Future<void> install(WidgetTester tester, List<String> manifests) =>
      tester.runAsync(() async {
        for (final m in manifests) {
          await registry.importText(m);
        }
      });

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: Consumer(
          builder: (context, ref, _) {
            // 与 TsumugiApp 一样在启动时创建下载队列。
            ref.watch(downloadManagerProvider);
            return MaterialApp.router(routerConfig: ref.watch(routerProvider));
          },
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

Future<void> _tapAndWait(
  WidgetTester tester,
  Finder target,
  Finder expected,
) async {
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pump();
  await _pumpUntil(tester, expected);
}

/// 等到 [sourceId] / [itemId] 的全部 unit 都已下载。
Future<void> _waitDownloaded(
  WidgetTester tester,
  _App app,
  String sourceId,
  String itemId,
  int count,
) async {
  final repo = app.container.read(downloadRepositoryProvider);
  final end = DateTime.now().add(const Duration(seconds: 60));
  while (true) {
    final units = (await tester.runAsync(repo.allUnits))!
        .where((u) => u.sourceId == sourceId && u.itemId == itemId)
        .toList();
    final failed = units.where((u) => u.status == DownloadStatus.failed);
    if (failed.isNotEmpty) {
      fail('下载失败：${failed.map((u) => '${u.unitId} ${u.errorCode}')}');
    }
    if (units.length == count &&
        units.every((u) => u.status == DownloadStatus.done)) {
      return;
    }
    if (DateTime.now().isAfter(end)) fail('下载超时：$units');
    await tester.pump(const Duration(milliseconds: 200));
  }
}

Future<String> _scriptManifest(
  TestMock server,
  String manifest,
  String script,
) async => jsonEncode({
  ...jsonDecode(await server.fixture(manifest)) as Map<String, dynamic>,
  'script': await server.fixture(script),
});

/// 由本地文件解码出来的图片（漫画页的 [RawImage] 无法区分来源，按 [Image] / 阅读器的 provider 判断）。
bool _isFileImage(Widget w) => w is Image && w.image is FileImage;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late TestMock server;
  late Directory downloads;

  setUp(() async {
    server = await TestMock.start();
    downloads = await (await getTemporaryDirectory()).createTemp('tsumugi_dl_');
  });
  tearDown(() async {
    await server.close();
    await downloads.delete(recursive: true);
  });

  testWidgets('下载漫画与带插图的小说章节 → 断网 → 离线阅读', (tester) async {
    final app = _App(server, downloads);
    await app.install(tester, [
      await _scriptManifest(
        server,
        'sources/mock_comic_script.json',
        'script/comic/source.js',
      ),
      await _scriptManifest(
        server,
        'sources/mock_novel_script.json',
        'script/novel/source.js',
      ),
    ]);
    await app.pump(tester);
    final router = app.container.read(routerProvider);

    // 漫画：只下载第 1 话（mock 站点只有这一话的页面）。
    router.push(ComicRoutes.detail(_comicId, _comicItem));
    await _pumpUntil(tester, find.text('第 1 话 落脚点'));
    await _tapAndWait(
      tester,
      find.widgetWithText(OutlinedButton, '下载'),
      find.text('开始下载'),
    );
    await tester.tap(find.text('起止章节'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('download-range-到')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1. 第 1 话 落脚点').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始下载'));
    await _pumpUntil(tester, find.text('已加入下载队列（1 章）'));
    await _waitDownloaded(tester, app, _comicId, _comicItem, 1);
    // 章节列表标出已下载。
    await _pumpUntil(tester, find.byIcon(Icons.download_done));

    // 小说：两章全部下载（第一章含章节内分页，共两张插图）。
    router.push(NovelRoutes.detail(_novelId, _novelItem));
    await _pumpUntil(tester, find.text('第二章 雨季'));
    await _tapAndWait(
      tester,
      find.widgetWithText(OutlinedButton, '下载'),
      find.text('开始下载'),
    );
    await tester.tap(find.text('开始下载'));
    await _pumpUntil(tester, find.text('已加入下载队列（2 章）'));
    await _waitDownloaded(tester, app, _novelId, _novelItem, 2);

    final imagesBefore = (await server.requests())
        .where((r) => r.host == 'img.example.com')
        .map((r) => r.path)
        .toSet();
    expect(
      imagesBefore,
      containsAll([
        '/pages/1/1/001.png',
        '/pages/1/1/003.png',
        '/static/novel/1-1.png',
        '/static/novel/1-2.png',
        '/static/novel/2-1.png',
      ]),
    );

    // 断网，回到书架，从「下载」标签打开。
    await tester.runAsync(server.goOffline);
    router.go('/library');
    await _pumpUntil(tester, find.widgetWithText(Tab, '下载'));
    await tester.tap(find.widgetWithText(Tab, '下载'));
    await _pumpUntil(tester, find.text('星之栖处'));
    // 等标签切换动画结束再点条目（冷启动时较慢，动画中点击可能落空）。
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('已下载 1 / 1 章'), findsOneWidget);
    expect(find.textContaining('已下载 2 / 2 章'), findsOneWidget);

    // 漫画：3 页都从本地文件解码。
    await _tapAndWait(tester, find.text('星之栖处'), find.text('第 1 话 落脚点'));
    await _tapAndWait(tester, find.text('第 1 话 落脚点'), find.text('1 / 3'));
    await _pumpUntil(tester, find.byType(RawImage));
    expect(find.textContaining('失败'), findsNothing);
    // 阅读器的工具栏默认隐藏，经路由返回到「下载」标签。
    router.pop();
    await _pumpUntil(tester, find.byTooltip('删除全部下载'));
    router.pop();
    await _pumpUntil(tester, find.text('青石巷的钟表匠'));
    await tester.pump(const Duration(milliseconds: 500));

    // 小说：正文与插图来自下载，章节内分页已拼接；目录来自快照（离线时详情取不到）。
    await _tapAndWait(tester, find.text('青石巷的钟表匠'), find.text('第一章 倒走的怀表'));
    await _tapAndWait(
      tester,
      find.text('第一章 倒走的怀表'),
      find.textContaining('一位客人送来一只怀表', findRichText: true),
    );
    await _pumpUntil(tester, find.byWidgetPredicate(_isFileImage));
    expect(find.byWidgetPredicate(_isFileImage), findsWidgets);
    expect(find.textContaining('［图片'), findsNothing);

    // 断网后没有任何请求到达服务器（断开的连接不记录；这里确认离线读取没有走网络层的成功路径）。
    final imagesAfter = (await server.requests())
        .where((r) => r.host == 'img.example.com')
        .map((r) => r.path)
        .toSet();
    expect(imagesAfter, imagesBefore);

    // 下载目录中只有哈希与序号构成的路径。
    final names = (await tester.runAsync(
      () => downloads.list(recursive: true).map((e) => e.path).toList(),
    ))!;
    for (final p in names) {
      final rel = p.substring(downloads.path.length + 1);
      expect(
        rel,
        matches(
          RegExp(
            r'^[0-9a-f]{32}([\\/][0-9a-f]{32}){0,2}'
            r'([\\/](\d{4}\.png|img-\d{4}\.png|unit\.json|chapter\.json|\.done))?$',
          ),
        ),
      );
    }
    await app.dispose(tester);
  });
}
