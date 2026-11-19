// M6 WebDAV 同步（architecture §4.6）：两台“设备”（两个数据库）经 mock 服务器的 WebDAV 同步书架与进度；
// 第二台设备走真实界面（设置 → WebDAV 同步），同步来的新源必须经预览确认后才安装。
//
// 运行方式同 app_flow_test.dart（Windows 在进程内启动 mock 服务器；Android / iOS 连接电脑上以
// --test-control 启动的 mock 服务器）。WebDAV 地址用 mock 服务器的回环地址（允许 http）。

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tsumugi/app/router.dart';
import 'package:tsumugi/core/storage/app_database.dart';
import 'package:tsumugi/features/explore/explore_preferences.dart';
import 'package:tsumugi/shared/history/history_repository.dart';
import 'package:tsumugi/shared/image/image_cache.dart';
import 'package:tsumugi/shared/image/image_providers.dart';
import 'package:tsumugi/shared/library/library_item.dart';
import 'package:tsumugi/shared/library/library_repository.dart';
import 'package:tsumugi/shared/sync/providers.dart';
import 'package:tsumugi/shared/sync/webdav_client.dart';
import 'package:tsumugi/sources/model/common.dart';
import 'package:tsumugi/sources/registry/providers.dart';
import 'package:tsumugi/sources/session/source_sessions.dart';

import '../test/core/network/mock_support.dart' show MockWebDav;
import '../test/core/storage/test_database.dart';
import 'test_mock.dart';

const _book1 = LibraryItem(
  sourceId: 'com.example.settings',
  itemId: '/book/1',
  title: '虚构漫画一',
  mediaType: MediaType.comic,
);

const _book2 = LibraryItem(
  sourceId: 'com.example.settings',
  itemId: '/book/2',
  title: '虚构漫画二',
  mediaType: MediaType.comic,
);

/// 一台设备的数据与同步服务（不带界面）。
class _Device {
  _Device(this.server);

  final TestMock server;
  final AppDatabase db = openTestDatabase();
  final credentials = MemoryCredentialStore(MockWebDav.password);
  late final registry = SourceRegistry(db);
  late final library = LibraryRepository(db);
  late final history = HistoryRepository(db);

  WebDavClient client(WebDavConfig config) =>
      WebDavClient(config, adapter: server.adapter());

  late final service = SyncService(
    store: SyncStore(db),
    credentials: credentials,
    registry: registry,
    clientFactory: client,
  );

  String get davUrl => '${server.origin}/dav/';
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

Future<void> _pumpUntilGone(WidgetTester tester, Finder finder) async {
  final end = DateTime.now().add(const Duration(seconds: 30));
  while (finder.evaluate().isNotEmpty) {
    if (DateTime.now().isAfter(end)) fail('超时：仍有 $finder');
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late TestMock server;

  setUp(() async => server = await TestMock.start());
  tearDown(() => server.close());

  testWidgets('两台设备经 WebDAV 同步书架与进度；新源需要确认', (tester) async {
    final a = _Device(server);
    final b = _Device(server);
    final manifest = await server.fixture('sources/settings_comic.json');

    // 设备 A：书架、进度、一个停用并改过设置的源，同步上去。
    await tester.runAsync(() async {
      await a.service.configure(
        serverUrl: a.davUrl,
        username: MockWebDav.username,
        remoteDir: 'Tsumugi/',
        password: MockWebDav.password,
      );
      await a.registry.importText(manifest);
      await a.registry.setEnabled('com.example.settings', false);
      await a.registry.setSettings('com.example.settings', {'quality': 'low'});
      await a.library.add(_book1);
      await a.history.recordProgress(
        _book1,
        unitId: 'c1',
        unitTitle: '第 1 话',
        page: 4,
        pageCount: 10,
      );
      expect((await a.service.sync()).uploaded, isTrue);
    });

    // 设备 B：完整应用，经设置页配置并同步。
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(b.db),
        credentialStoreProvider.overrideWithValue(b.credentials),
        webDavClientFactoryProvider.overrideWithValue(b.client),
        sessionPersistenceProvider.overrideWithValue(null),
        diskImageCacheProvider.overrideWithValue(const NoDiskImageCache()),
        explorePreferencesStoreProvider.overrideWithValue(
          MemoryExplorePreferencesStore(),
        ),
      ],
    );
    b.credentials.password = null;
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

    container.read(routerProvider).go('/settings');
    await _pumpUntil(tester, find.text('WebDAV 同步'));
    await tester.tap(find.text('WebDAV 同步'));
    await _pumpUntil(tester, find.byKey(const ValueKey('sync-url')));
    await tester.enterText(find.byKey(const ValueKey('sync-url')), b.davUrl);
    await tester.enterText(
      find.byKey(const ValueKey('sync-user')),
      MockWebDav.username,
    );
    await tester.enterText(
      find.byKey(const ValueKey('sync-password')),
      MockWebDav.password,
    );
    await tester.tap(find.text('保存'));
    await _pumpUntil(tester, find.text('立即同步'));
    expect(b.credentials.password, MockWebDav.password);

    await tester.tap(find.text('立即同步'));
    await _pumpUntil(tester, find.text('待安装的源'));

    await tester.runAsync(() async {
      // 书架与进度已同步过来。
      expect(
        await b.library.contains('com.example.settings', '/book/1'),
        isTrue,
      );
      final progress = await b.history.latestProgress(
        'com.example.settings',
        '/book/1',
      );
      expect(progress?.page, 4);
      // 源没有自动安装。
      expect(await b.registry.getAll(), isEmpty);
    });

    // 预览确认后安装，A 上的启用状态与设置随之生效。
    await tester.tap(find.text('预览'));
    await _pumpUntil(tester, find.text('安装同步来的源'));
    expect(find.text('example.com'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '安装'));
    await _pumpUntilGone(tester, find.text('安装同步来的源'));
    await _pumpUntilGone(tester, find.text('待安装的源'));

    await tester.runAsync(() async {
      final installed = (await b.registry.get('com.example.settings'))!;
      expect(installed.enabled, isFalse);
      expect(installed.settings['quality'], 'low');
      // B 加一本书再同步，A 同步后看到。
      await b.library.add(_book2);
    });
    final before = (await tester.runAsync(() => b.service.store.ensureState()))!
        .lastSyncAt;
    await tester.tap(find.text('立即同步'));
    await tester.pump();
    // 等 B 的这次同步完成（上次同步时间更新）。
    final end = DateTime.now().add(const Duration(seconds: 30));
    while (true) {
      final state = (await tester.runAsync(
        () => b.service.store.ensureState(),
      ))!;
      if (state.lastSyncAt != before &&
          !container.read(syncServiceProvider).isRunning) {
        break;
      }
      if (DateTime.now().isAfter(end)) {
        fail('B 同步超时：${state.lastError}');
      }
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.runAsync(() async {
      await a.service.sync();
      expect(
        await a.library.contains('com.example.settings', '/book/2'),
        isTrue,
      );
      // 远端文件中没有密码。
      final requests = await server.requests();
      expect(requests.where((r) => r.path.startsWith('/dav/')), isNotEmpty);
      expect(
        jsonEncode([for (final r in requests) r.body]),
        isNot(contains(MockWebDav.password)),
      );
    });

    await tester.pumpWidget(const SizedBox());
    container.dispose();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(() async {
      a.service.dispose();
      await a.db.close();
      await b.db.close();
    });
  });
}
