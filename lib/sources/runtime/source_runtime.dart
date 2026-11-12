import 'dart:async';

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../declarative/declarative_source.dart';
import '../declarative/declarative_source_factory.dart';
import '../registry/providers.dart';
import '../script/script_source.dart';
import '../source.dart';

part 'source_runtime.g.dart';

/// 需要释放资源（worker isolate、HTTP 客户端等）的 [Source]。测试替身可实现此接口。
abstract interface class DisposableSource implements Source {
  void dispose();
}

/// 释放 [source] 持有的资源；不需要释放的源什么也不做。
void disposeSource(Source source) => switch (source) {
  DisposableSource() => source.dispose(),
  ScriptSource() => source.dispose(),
  ManagedDeclarativeSource() => source.dispose(),
  DeclarativeSource() => source.dispose(),
  _ => null,
};

/// 源无法实例化：未安装、已删除、已禁用或清单损坏。
class SourceUnavailableException implements Exception {
  const SourceUnavailableException(this.sourceId, this.reason);

  final String sourceId;

  /// 面向用户的说明（中文）。
  final String reason;

  @override
  String toString() => 'SourceUnavailableException($sourceId: $reason)';
}

/// 决定缓存的实例是否过时的源状态：id、清单哈希（升级 / 覆盖安装）、启用状态、清单是否可用。
final class SourceRevision {
  const SourceRevision(this.installed);

  final InstalledSource installed;

  @override
  bool operator ==(Object other) =>
      other is SourceRevision &&
      other.installed.id == installed.id &&
      other.installed.manifestSha256 == installed.manifestSha256 &&
      other.installed.enabled == installed.enabled &&
      (other.installed.manifest == null) == (installed.manifest == null);

  @override
  int get hashCode => Object.hash(
    installed.id,
    installed.manifestSha256,
    installed.enabled,
    installed.manifest == null,
  );
}

class _Entry {
  _Entry();

  late final Future<Source> future;

  /// 创建时读到的源状态；读到之前为 null。
  SourceRevision? revision;
  bool evicted = false;
}

/// 按 sourceId 缓存可运行的 [Source] 实例（经 [SourceFactories] 创建）。
///
/// 自行订阅注册表：源被禁用、删除、升级（清单变化）时把实例移出缓存并释放
/// （脚本源的 worker 随之结束），下次 [get] 时按新状态重建。创建失败不缓存，下次 [get] 重试。
class SourceRuntime {
  SourceRuntime(this._registry, this._factories) {
    _subscription = _registry.watchAll().listen(_onChange);
  }

  final SourceRegistry _registry;
  final SourceFactories _factories;
  late final StreamSubscription<List<InstalledSource>> _subscription;
  final _entries = <String, _Entry>{};
  final _evictions = StreamController<String>.broadcast(sync: true);
  bool _disposed = false;

  /// 缓存的实例被移除（源状态变化）时发出其 sourceId。
  Stream<String> get evictions => _evictions.stream;

  /// 获取（必要时创建）[sourceId] 的实例。源不可用时以 [SourceUnavailableException] 失败；
  /// 创建失败时抛出工厂的错误（通常是 [SourceException]）。
  Future<Source> get(String sourceId) {
    if (_disposed) throw StateError('SourceRuntime 已释放');
    final cached = _entries[sourceId];
    if (cached != null) return cached.future;
    final entry = _Entry();
    _entries[sourceId] = entry;
    entry.future = _create(sourceId, entry);
    entry.future.then<void>(
      (source) {
        // 创建期间已被移出缓存：这个实例已经过时。
        if (entry.evicted) disposeSource(source);
      },
      onError: (Object _) {
        if (identical(_entries[sourceId], entry)) _entries.remove(sourceId);
      },
    );
    return entry.future;
  }

  Future<Source> _create(String sourceId, _Entry entry) async {
    final installed = await _registry.get(sourceId);
    if (installed == null) {
      throw SourceUnavailableException(sourceId, '源未安装或已被删除');
    }
    entry.revision = SourceRevision(installed);
    if (!installed.enabled) {
      throw SourceUnavailableException(sourceId, '「${installed.name}」已禁用');
    }
    final manifest = installed.manifest;
    if (manifest == null) {
      throw SourceUnavailableException(
        sourceId,
        '「${installed.name}」的清单无法加载：${installed.loadError ?? '未知原因'}',
      );
    }
    return _factories.create(manifest);
  }

  void _onChange(List<InstalledSource> all) {
    final current = {for (final s in all) s.id: s};
    for (final MapEntry(key: id, value: entry) in _entries.entries.toList()) {
      final revision = entry.revision;
      if (revision == null) continue; // 尚未读到状态，创建时会读到最新的。
      final now = current[id];
      if (now != null && SourceRevision(now) == revision) continue;
      _evict(id, entry);
    }
  }

  void _evict(String id, _Entry entry, {bool notify = true}) {
    _entries.remove(id);
    entry.evicted = true;
    entry.future.then<void>(disposeSource, onError: (Object _) {});
    if (notify) _evictions.add(id);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_subscription.cancel());
    for (final MapEntry(:key, :value) in _entries.entries.toList()) {
      _evict(key, value, notify: false);
    }
    unawaited(_evictions.close());
  }
}

@Riverpod(keepAlive: true)
SourceRuntime sourceRuntime(Ref ref) {
  final runtime = SourceRuntime(
    ref.watch(sourceRegistryProvider),
    ref.watch(sourceFactoriesProvider),
  );
  ref.onDispose(runtime.dispose);
  return runtime;
}

/// [sourceId] 的实例；源被禁用 / 删除 / 升级时自动失效并重新获取，
/// 依赖它的 provider（如详情）随之重建。
@riverpod
Future<Source> sourceInstance(Ref ref, String sourceId) {
  final runtime = ref.watch(sourceRuntimeProvider);
  final sub = runtime.evictions
      .where((id) => id == sourceId)
      .listen((_) => ref.invalidateSelf());
  ref.onDispose(sub.cancel);
  return runtime.get(sourceId);
}
