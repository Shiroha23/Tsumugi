import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../core/storage/app_database.dart';
import '../model/common.dart';
import 'installed_source.dart';
import 'source_registry.dart';

export 'installed_source.dart';
export 'manifest_import.dart';
export 'source_factory.dart';
export 'source_registry.dart';

part 'providers.g.dart';

@Riverpod(keepAlive: true)
SourceRegistry sourceRegistry(Ref ref) =>
    SourceRegistry(ref.watch(appDatabaseProvider));

/// 全部已安装源（按排序），可按类型过滤。
@riverpod
Stream<List<InstalledSource>> installedSources(Ref ref, {MediaType? type}) =>
    ref.watch(sourceRegistryProvider).watchAll(type: type);

/// 已启用且清单可用的源，可按类型过滤。
@riverpod
Stream<List<InstalledSource>> enabledSources(Ref ref, {MediaType? type}) => ref
    .watch(sourceRegistryProvider)
    .watchAll(type: type, enabled: true)
    .map((list) => list.where((s) => s.isUsable).toList());
