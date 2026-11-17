import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../sources/model/common.dart';
import '../../sources/model/manifest.dart';
import '../../sources/registry/providers.dart';
import '../../sources/runtime/source_runtime.dart';
import '../../sources/source.dart';
import 'explore_preferences.dart';

part 'explore_controller.g.dart';

/// 一次 `explore()` / `exploreList()`（含首次创建源实例）的最长等待时间。
@Riverpod(keepAlive: true)
Duration exploreTimeout(Ref ref) => const Duration(seconds: 30);

/// 源是否（可能）提供发现页，只看清单、不创建源实例：
///
/// - 声明式：`rules.explore` 是非空数组。
/// - 脚本：脚本源码中出现 `explore` 这个名字。ES 模块的导出名是静态的，导出了 `explore`
///   的脚本一定包含它，所以不会漏掉源；误判（只是出现了这个词）的源在调用时得到
///   `E_UNSUPPORTED`，按出错显示。
bool supportsExplore(SourceManifest manifest) => switch (manifest.engine) {
  SourceEngine.declarative => switch (manifest.rules?['explore']) {
    final List<Object?> list => list.isNotEmpty,
    _ => false,
  },
  SourceEngine.script => _exploreName.hasMatch(manifest.script ?? ''),
};

final _exploreName = RegExp(r'\bexplore\b');

/// 已启用、清单可用且提供发现页的源（按注册表排序，所有媒体类型）。
@riverpod
Stream<List<InstalledSource>> exploreSources(Ref ref) => ref
    .watch(sourceRegistryProvider)
    .watchAll(enabled: true)
    .map(
      (list) => [
        for (final s in list)
          if (s.isUsable && supportsExplore(s.manifest!)) s,
      ],
    );

/// 当前分类的条目列表（逐页追加）。
@immutable
final class ExploreFeed {
  const ExploreFeed({
    this.items = const [],
    this.page = 0,
    this.hasMore = false,
    this.loading = false,
    this.error,
  });

  final List<SearchItem> items;

  /// 已成功加载的最后一页（从 1 开始）；0 表示还没有任何一页成功。
  final int page;
  final bool hasMore;

  /// 正在加载第 [page] + 1 页。
  final bool loading;

  /// 最近一次加载的错误。
  final Object? error;

  ExploreFeed copyWith({
    List<SearchItem>? items,
    int? page,
    bool? hasMore,
    bool? loading,
    Object? Function()? error,
  }) => ExploreFeed(
    items: items ?? this.items,
    page: page ?? this.page,
    hasMore: hasMore ?? this.hasMore,
    loading: loading ?? this.loading,
    error: error == null ? this.error : error(),
  );
}

@immutable
final class ExploreState {
  const ExploreState({
    this.ready = false,
    this.source,
    this.categories,
    this.categoryId,
    this.feed = const ExploreFeed(),
  });

  /// 已读到源列表与上次的选择；为 false 时界面显示加载中。
  final bool ready;

  /// 当前源；[ready] 且为 null 表示没有可用的源。
  final InstalledSource? source;

  /// 当前源的分类（`explore()`）；还没选源时为 null。
  final AsyncValue<List<ExploreCategory>>? categories;

  final String? categoryId;
  final ExploreFeed feed;

  ExploreState copyWith({
    InstalledSource? source,
    AsyncValue<List<ExploreCategory>>? categories,
    String? Function()? categoryId,
    ExploreFeed? feed,
  }) => ExploreState(
    ready: ready,
    source: source ?? this.source,
    categories: categories ?? this.categories,
    categoryId: categoryId == null ? this.categoryId : categoryId(),
    feed: feed ?? this.feed,
  );
}

/// 发现页：选源 → 分类 → 可翻页的条目列表（architecture §5.1）。
///
/// 上次选择的源与分类经 [explorePreferencesStoreProvider] 保存，再次打开时恢复；
/// 该源已不可用时改选第一个可用源。
@riverpod
class ExploreController extends _$ExploreController {
  /// 每次换源 / 换分类递增；过时的结果按它丢弃。
  int _generation = 0;

  List<InstalledSource>? _sources;
  ExploreSelection? _saved;

  @override
  ExploreState build() {
    ref.listen(exploreSourcesProvider, (_, next) {
      if (next case AsyncData(:final value)) {
        _sources = value;
        scheduleMicrotask(_sync);
      }
    }, fireImmediately: true);
    // 当前源被升级 / 重新安装时，运行时移除旧实例：按新规则重新加载分类与列表。
    final evictions = ref
        .read(sourceRuntimeProvider)
        .evictions
        .listen((id) => scheduleMicrotask(() => _onEvicted(id)));
    ref.onDispose(evictions.cancel);
    ref
        .read(explorePreferencesStoreProvider)
        .load()
        .then(
          (s) => _saved = s,
          onError: (Object _) => _saved = const ExploreSelection(),
        )
        .whenComplete(() => scheduleMicrotask(_sync));
    return const ExploreState();
  }

  /// 源列表或上次选择到达后：当前源仍可用则不动，否则恢复上次的源或改选第一个。
  void _sync() {
    if (!ref.mounted) return;
    final sources = _sources;
    final saved = _saved;
    if (sources == null || saved == null) return;
    final current = state.source;
    final updated = current == null
        ? null
        : sources.where((s) => s.id == current.id).firstOrNull;
    if (updated != null) {
      // 仍可用：只换成最新的清单（名称、类型）；重新加载由 [_onEvicted] 负责。
      if (updated.manifestSha256 != current!.manifestSha256) {
        state = state.copyWith(source: updated);
      }
      return;
    }
    final next =
        sources.where((s) => s.id == saved.sourceId).firstOrNull ??
        sources.firstOrNull;
    if (next == null) {
      _generation++;
      state = const ExploreState(ready: true);
      return;
    }
    unawaited(_open(next, next.id == saved.sourceId ? saved.categoryId : null));
  }

  void _onEvicted(String sourceId) {
    if (!ref.mounted || sourceId != state.source?.id) return;
    final latest = _sources?.where((s) => s.id == sourceId).firstOrNull;
    // 已不在列表中（禁用 / 删除）：等源列表更新后由 [_sync] 改选。
    if (latest == null) return;
    unawaited(_open(latest, state.categoryId));
  }

  /// 切换到 [sourceId]（必须在 [exploreSourcesProvider] 中）。
  Future<void> selectSource(String sourceId) async {
    if (sourceId == state.source?.id) return;
    final source = _sources?.where((s) => s.id == sourceId).firstOrNull;
    if (source == null) return;
    await _open(source, null);
  }

  /// 重新加载当前源的分类与当前分类的第一页（刷新 / 分类加载失败后的重试）。
  Future<void> reload() async {
    final current = state.source;
    if (current == null) return;
    final source =
        _sources?.where((s) => s.id == current.id).firstOrNull ?? current;
    await _open(source, state.categoryId);
  }

  Future<void> selectCategory(String categoryId) async {
    final source = state.source;
    final categories = state.categories?.value;
    if (source == null ||
        categoryId == state.categoryId ||
        categories == null ||
        !categories.any((c) => c.id == categoryId)) {
      return;
    }
    final gen = ++_generation;
    state = state.copyWith(
      categoryId: () => categoryId,
      feed: const ExploreFeed(loading: true),
    );
    _persist();
    await _load(gen, source.id, categoryId, 1);
  }

  /// 加载当前分类的下一页（也用于失败后的重试）。
  Future<void> loadMore() async {
    final source = state.source;
    final categoryId = state.categoryId;
    final feed = state.feed;
    if (source == null || categoryId == null || feed.loading) return;
    if (feed.page > 0 && !feed.hasMore && feed.error == null) return;
    state = state.copyWith(
      feed: feed.copyWith(loading: true, error: () => null),
    );
    await _load(_generation, source.id, categoryId, feed.page + 1);
  }

  Future<void> _open(InstalledSource source, String? preferredCategory) async {
    final gen = ++_generation;
    state = ExploreState(
      ready: true,
      source: source,
      categories: const AsyncLoading(),
      categoryId: preferredCategory,
    );
    _persist();
    final List<ExploreCategory> categories;
    try {
      categories = await _call(source.id, (s) => s.explore());
    } catch (e, st) {
      if (_stale(gen)) return;
      state = state.copyWith(categories: AsyncError(e, st));
      return;
    }
    if (_stale(gen)) return;
    final category =
        categories.where((c) => c.id == preferredCategory).firstOrNull ??
        categories.firstOrNull;
    state = state.copyWith(
      categories: AsyncData(categories),
      categoryId: () => category?.id,
      feed: category == null ? null : const ExploreFeed(loading: true),
    );
    if (category == null) return;
    _persist();
    await _load(gen, source.id, category.id, 1);
  }

  Future<void> _load(
    int gen,
    String sourceId,
    String categoryId,
    int page,
  ) async {
    try {
      final result = await _call(
        sourceId,
        (s) => s.exploreList(categoryId, page),
      );
      if (_stale(gen)) return;
      final feed = state.feed;
      state = state.copyWith(
        feed: feed.copyWith(
          items: [...feed.items, ...result.items],
          page: page,
          hasMore: result.hasMore,
          loading: false,
          error: () => null,
        ),
      );
    } catch (e) {
      if (_stale(gen)) return;
      state = state.copyWith(
        feed: state.feed.copyWith(loading: false, error: () => e),
      );
    }
  }

  Future<T> _call<T>(String sourceId, Future<T> Function(Source) run) =>
      () async {
        final source = await ref.read(sourceRuntimeProvider).get(sourceId);
        return run(source);
      }().timeout(ref.read(exploreTimeoutProvider));

  bool _stale(int gen) => !ref.mounted || gen != _generation;

  void _persist() {
    final selection = ExploreSelection(
      sourceId: state.source?.id,
      categoryId: state.categoryId,
    );
    _saved = selection;
    unawaited(ref.read(explorePreferencesStoreProvider).save(selection));
  }
}
