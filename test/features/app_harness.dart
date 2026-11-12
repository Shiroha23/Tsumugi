import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tsumugi/app/router.dart';
import 'package:tsumugi/core/storage/app_database.dart';
import 'package:tsumugi/sources/registry/providers.dart';

import '../core/storage/test_database.dart';
import '../sources/runtime/runtime_support.dart';

/// 用真实路由（[routerProvider]）、内存数据库与 [FakeFactory] 启动整个应用。
class AppHarness {
  AppHarness(this.factory);

  final FakeFactory factory;
  final AppDatabase db = openTestDatabase();
  late final SourceRegistry registry = SourceRegistry(db);
  late final ProviderContainer container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      sourceFactoriesProvider.overrideWithValue(SourceFactories([factory])),
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
