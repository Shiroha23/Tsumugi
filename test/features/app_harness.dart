import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tsumugi/app/router.dart';
import 'package:tsumugi/core/network/source_http_client.dart';
import 'package:tsumugi/core/storage/app_database.dart';
import 'package:tsumugi/features/comic/reader/reader_preferences.dart';
import 'package:tsumugi/features/novel/reader/novel_reader_preferences.dart';
import 'package:tsumugi/shared/image/image_cache.dart';
import 'package:tsumugi/shared/image/image_providers.dart';
import 'package:tsumugi/shared/webview/providers.dart';
import 'package:tsumugi/sources/registry/providers.dart';

import '../core/storage/test_database.dart';
import '../shared/webview/webview_fakes.dart';
import '../sources/runtime/runtime_support.dart';

/// 用真实路由（[routerProvider]）、内存数据库与 [FakeFactory] 启动整个应用。
class AppHarness {
  AppHarness(
    this.factory, {
    MemoryNovelReaderPreferencesStore? novelPreferences,
  }) : novelPreferences =
           novelPreferences ?? MemoryNovelReaderPreferencesStore();

  final FakeFactory factory;

  /// 「打开验证页」不启动真实 WebView。
  final verification = FakeSourceVerification();

  /// 小说阅读器偏好（内存）。
  final MemoryNovelReaderPreferencesStore novelPreferences;
  final AppDatabase db = openTestDatabase();
  late final SourceRegistry registry = SourceRegistry(db);
  late final ProviderContainer container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      sourceFactoriesProvider.overrideWithValue(SourceFactories([factory])),
      // 图片不走网络与磁盘：封面 / 漫画页显示失败占位即可。
      diskImageCacheProvider.overrideWithValue(const NoDiskImageCache()),
      imageHttpClientsProvider.overrideWithValue(const _NoImageClients()),
      // 阅读器偏好默认存文件（path_provider），测试中用内存。
      readerPreferencesStoreProvider.overrideWithValue(
        MemoryReaderPreferencesStore(),
      ),
      sourceVerificationProvider.overrideWithValue(verification),
      novelReaderPreferencesStoreProvider.overrideWithValue(novelPreferences),
    ],
  );

  GoRouter get router => container.read(routerProvider);

  /// 在真实异步中安装源（drift 在 fake async 外更可靠）。
  Future<void> install(WidgetTester tester, List<String> manifests) =>
      tester.runAsync(() async {
        for (final m in manifests) {
          await registry.importText(m);
        }
      });

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: Consumer(
          builder: (context, ref, _) =>
              MaterialApp.router(routerConfig: ref.watch(routerProvider)),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 卸载并释放，让 drift 的 stream 在测试结束前关闭。
  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    await tester.pumpAndSettle();
    await tester.runAsync(db.close);
  }
}

class _NoImageClients implements ImageHttpClients {
  const _NoImageClients();

  @override
  Future<SourceHttpClient> clientFor(String sourceId) =>
      Future.error(StateError('测试中不加载图片'));
}
