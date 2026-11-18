import 'dart:async';

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../core/storage/app_database.dart';
import '../registry/providers.dart';
import 'repository_http_client.dart';
import 'repository_service.dart';

export 'repository_exception.dart';
export 'repository_http_client.dart';
export 'repository_index.dart';
export 'repository_service.dart';

part 'providers.g.dart';

/// 仓库专用的 HTTP 客户端；测试中覆盖为接到 mock 服务器的实例。
@Riverpod(keepAlive: true)
RepositoryHttpClient repositoryHttpClient(Ref ref) {
  final client = RepositoryHttpClient();
  ref.onDispose(client.close);
  return client;
}

@Riverpod(keepAlive: true)
RepositoryService repositoryService(Ref ref) => RepositoryService(
  ref.watch(appDatabaseProvider),
  ref.watch(sourceRegistryProvider),
  ref.watch(repositoryHttpClientProvider),
);

/// 已订阅的仓库（按加入时间）。
@riverpod
Stream<List<SubscribedRepository>> subscribedRepositories(Ref ref) =>
    ref.watch(repositoryServiceProvider).watchAll();

/// 来自仓库的已装源的状态（可更新 / 需要更新客户端 / 仓库已移除），按源 id。
@riverpod
Map<String, SourceRepositoryStatus> sourceRepositoryStatus(Ref ref) {
  final installed = ref.watch(installedSourcesProvider()).value;
  final repos = ref.watch(subscribedRepositoriesProvider).value;
  if (installed == null || repos == null) return const {};
  return sourceRepositoryStatuses(installed, repos);
}

/// 更新检查的间隔（architecture §4.4）。
const repositoryCheckInterval = Duration(hours: 24);

/// 应用启动时检查一次全部仓库，之后每 [repositoryCheckInterval] 一次。由应用根组件监听以启动。
///
/// 只记录检查结果（“可更新”由 [sourceRepositoryStatusProvider] 派生），不自动安装。
@Riverpod(keepAlive: true)
void repositoryUpdateScheduler(Ref ref) {
  final service = ref.watch(repositoryServiceProvider);
  void check() => unawaited(service.refreshAll().catchError((Object _) {}));
  final startup = Timer(Duration.zero, check);
  final periodic = Timer.periodic(repositoryCheckInterval, (_) => check());
  ref.onDispose(() {
    startup.cancel();
    periodic.cancel();
  });
}
