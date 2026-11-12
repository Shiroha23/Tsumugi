import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../sources/model/common.dart';
import '../../sources/registry/providers.dart';
import '../../sources/runtime/source_runtime.dart';

part 'search_controller.g.dart';

/// 单个源一次搜索（含首次创建源实例）的最长等待时间。
@Riverpod(keepAlive: true)
Duration searchTimeout(Ref ref) => const Duration(seconds: 30);

/// 一个源的搜索结果分组。
@immutable
final class SourceSearchGroup {
  const SourceSearchGroup({
    required this.sourceId,
    required this.sourceName,
    this.items = const [],
    this.page = 0,
    this.hasMore = false,
    this.loading = false,
    this.error,
  });

  final String sourceId;
  final String sourceName;
  final List<SearchItem> items;

  /// 已成功加载的最后一页（从 1 开始）；0 表示还没有任何一页成功。
  final int page;
  final bool hasMore;

  /// 正在加载第 [page] + 1 页。
  final bool loading;

  /// 最近一次加载的错误（[SourceException]、[TimeoutException] 等）。
  final Object? error;

  SourceSearchGroup copyWith({
    List<SearchItem>? items,
    int? page,
    bool? hasMore,
    bool? loading,
    Object? Function()? error,
  }) => SourceSearchGroup(
    sourceId: sourceId,
    sourceName: sourceName,
    items: items ?? this.items,
    page: page ?? this.page,
    hasMore: hasMore ?? this.hasMore,
    loading: loading ?? this.loading,
    error: error == null ? this.error : error(),
  );
}

@immutable
final class SearchState {
  const SearchState({
    this.keyword = '',
    this.type = MediaType.comic,
    this.groups = const [],
    this.started = false,
  });

  final String keyword;
  final MediaType type;

  /// 按源排序的分组；每个源的结果到达时就地更新（流式出现）。
  final List<SourceSearchGroup> groups;

  /// 是否已经发起过搜索（区分「还没搜」和「没有可用源」）。
  final bool started;

  SearchState copyWith({MediaType? type, List<SourceSearchGroup>? groups}) =>
      SearchState(
        keyword: keyword,
        type: type ?? this.type,
        groups: groups ?? this.groups,
        started: started,
      );
}

/// 对所有已启用的源并发搜索（architecture §5.1）。单源失败 / 超时只影响自己的分组。
@riverpod
class SourceSearchController extends _$SourceSearchController {
  /// 每次新搜索递增；过时的结果按它丢弃。
  int _generation = 0;

  @override
  SearchState build() => const SearchState();

  /// 切换媒体类型；已有关键词时按新类型重新搜索。
  Future<void> setType(MediaType type) async {
    if (type == state.type) return;
    state = state.copyWith(type: type);
    if (state.keyword.isNotEmpty) await search(state.keyword);
  }

  Future<void> search(String keyword) async {
    final kw = keyword.trim();
    if (kw.isEmpty) return;
    final gen = ++_generation;
    final type = state.type;
    final sources = await ref.read(sourceRegistryProvider).enabled(type: type);
    if (!ref.mounted || gen != _generation) return;
    state = SearchState(
      keyword: kw,
      type: type,
      started: true,
      groups: [
        for (final s in sources)
          SourceSearchGroup(sourceId: s.id, sourceName: s.name, loading: true),
      ],
    );
    await Future.wait([for (final s in sources) _load(gen, s.id, kw, 1)]);
  }

  /// 加载 [sourceId] 的下一页（也用于失败后的重试）。
  Future<void> loadMore(String sourceId) async {
    final group = _group(sourceId);
    if (group == null || group.loading) return;
    if (group.page > 0 && !group.hasMore && group.error == null) return;
    _update(sourceId, (g) => g.copyWith(loading: true, error: () => null));
    await _load(_generation, sourceId, state.keyword, group.page + 1);
  }

  Future<void> _load(int gen, String sourceId, String keyword, int page) async {
    final timeout = ref.read(searchTimeoutProvider);
    try {
      final result = await () async {
        final source = await ref.read(sourceRuntimeProvider).get(sourceId);
        return source.search(keyword, page);
      }().timeout(timeout);
      if (!ref.mounted || gen != _generation) return;
      _update(
        sourceId,
        (g) => g.copyWith(
          items: [...g.items, ...result.items],
          page: page,
          hasMore: result.hasMore,
          loading: false,
          error: () => null,
        ),
      );
    } catch (e) {
      if (!ref.mounted || gen != _generation) return;
      _update(sourceId, (g) => g.copyWith(loading: false, error: () => e));
    }
  }

  SourceSearchGroup? _group(String sourceId) =>
      state.groups.where((g) => g.sourceId == sourceId).firstOrNull;

  void _update(
    String sourceId,
    SourceSearchGroup Function(SourceSearchGroup) change,
  ) {
    state = state.copyWith(
      groups: [
        for (final g in state.groups) g.sourceId == sourceId ? change(g) : g,
      ],
    );
  }
}
