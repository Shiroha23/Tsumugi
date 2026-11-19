import 'package:flutter/widgets.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../core/storage/app_database.dart' show appDatabaseProvider;
import '../../sources/registry/providers.dart';
import 'credential_store.dart';
import 'sync_scheduler.dart';
import 'sync_service.dart';
import 'sync_store.dart';

export 'credential_store.dart';
export 'sync_exception.dart';
export 'sync_scheduler.dart';
export 'sync_service.dart';
export 'sync_store.dart';

part 'providers.g.dart';

/// WebDAV 密码的存储；测试中覆盖为 [MemoryCredentialStore]。
@Riverpod(keepAlive: true)
CredentialStore credentialStore(Ref ref) => SecureCredentialStore();

/// 创建 WebDAV 客户端；测试中覆盖为接到 mock 服务器的实现。
@Riverpod(keepAlive: true)
WebDavClientFactory webDavClientFactory(Ref ref) => defaultWebDavClient;

@Riverpod(keepAlive: true)
SyncService syncService(Ref ref) {
  final service = SyncService(
    store: SyncStore(ref.watch(appDatabaseProvider)),
    credentials: ref.watch(credentialStoreProvider),
    registry: ref.watch(sourceRegistryProvider),
    clientFactory: ref.watch(webDavClientFactoryProvider),
  );
  ref.onDispose(service.dispose);
  return service;
}

/// 同步状态（配置、上次同步、错误、待安装的源）。
@riverpod
Stream<SyncStatus> syncStatus(Ref ref) =>
    ref.watch(syncServiceProvider).store.watchStatus();

/// 是否有同步正在进行。
@riverpod
Stream<bool> syncRunning(Ref ref) async* {
  final service = ref.watch(syncServiceProvider);
  yield service.isRunning;
  yield* service.runningChanges;
}

/// 自动同步（启动、回到前台、本地改动后）。由应用根组件持有。
@Riverpod(keepAlive: true)
SyncScheduler syncScheduler(Ref ref) {
  final scheduler = SyncScheduler(
    service: ref.watch(syncServiceProvider),
    db: ref.watch(appDatabaseProvider),
  );
  final lifecycle = AppLifecycleListener(onResume: scheduler.onResume);
  ref.onDispose(() {
    lifecycle.dispose();
    scheduler.dispose();
  });
  scheduler.start();
  return scheduler;
}
