import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/source_error_view.dart';
import '../../sources/registry/providers.dart';
import '../common/search_item_tile.dart';
import '../sources/labels.dart';
import 'explore_controller.dart';

/// 发现页：浏览一个源的分类（docs/source-spec.md §3 `explore`、§4.1 `explore()` / `exploreList()`）。
class ExplorePage extends ConsumerWidget {
  const ExplorePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(exploreControllerProvider);
    final sources = ref.watch(exploreSourcesProvider).value ?? const [];
    final controller = ref.read(exploreControllerProvider.notifier);
    final source = state.source;

    final Widget body;
    if (!state.ready) {
      body = const Center(child: CircularProgressIndicator());
    } else if (source == null) {
      body = const EmptyState(
        icon: Icons.explore_off_outlined,
        message: '没有提供发现页的已启用源\n先在「源」页面导入并启用',
      );
    } else {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: DropdownButton<String>(
              key: const ValueKey('explore-source'),
              isExpanded: true,
              value: sources.any((s) => s.id == source.id) ? source.id : null,
              hint: Text(source.name),
              onChanged: (id) {
                if (id != null) controller.selectSource(id);
              },
              items: [
                for (final s in sources)
                  DropdownMenuItem(
                    value: s.id,
                    child: Text(
                      '${s.name}（${s.type.label}）',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: _CategoryArea(state: state, source: source),
          ),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('发现'),
        actions: [
          if (source != null)
            IconButton(
              tooltip: '刷新',
              icon: const Icon(Icons.refresh),
              onPressed: controller.reload,
            ),
        ],
      ),
      body: body,
    );
  }
}

class _CategoryArea extends ConsumerWidget {
  const _CategoryArea({required this.state, required this.source});

  final ExploreState state;
  final InstalledSource source;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(exploreControllerProvider.notifier);
    switch (state.categories) {
      case null || AsyncLoading():
        return const Center(child: CircularProgressIndicator());
      case AsyncError(:final error):
        return SourceErrorView(
          error: error,
          sourceId: source.id,
          onRetry: controller.reload,
        );
      case AsyncData(:final value) when value.isEmpty:
        return const EmptyState(
          icon: Icons.category_outlined,
          message: '这个源没有发现页分类',
        );
      case AsyncData(:final value):
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Row(
                children: [
                  for (final c in value)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        key: ValueKey('explore-category-${c.id}'),
                        label: Text(c.name),
                        selected: state.categoryId == c.id,
                        onSelected: (_) => controller.selectCategory(c.id),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: _Feed(feed: state.feed, source: source),
            ),
          ],
        );
    }
  }
}

class _Feed extends ConsumerWidget {
  const _Feed({required this.feed, required this.source});

  final ExploreFeed feed;
  final InstalledSource source;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(exploreControllerProvider.notifier);
    final error = feed.error;
    if (feed.items.isEmpty) {
      if (feed.loading) {
        return const Center(child: CircularProgressIndicator());
      }
      if (error != null) {
        return SourceErrorView(
          error: error,
          sourceId: source.id,
          onRetry: controller.loadMore,
        );
      }
      if (feed.page > 0) {
        return const EmptyState(
          icon: Icons.inbox_outlined,
          message: '这个分类暂时没有内容',
        );
      }
    }

    final Widget? footer;
    if (feed.loading) {
      footer = const Padding(
        padding: EdgeInsets.all(8),
        child: Center(child: CircularProgressIndicator()),
      );
    } else if (error != null) {
      footer = SourceErrorView(
        error: error,
        sourceId: source.id,
        onRetry: controller.loadMore,
        compact: true,
      );
    } else if (feed.hasMore) {
      footer = Align(
        child: TextButton(
          onPressed: controller.loadMore,
          child: const Text('加载更多'),
        ),
      );
    } else {
      footer = null;
    }

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: feed.items.length + (footer == null ? 0 : 1),
      itemBuilder: (context, i) => i < feed.items.length
          ? SearchItemTile(
              sourceId: source.id,
              item: feed.items[i],
              type: source.type,
            )
          : footer!,
    );
  }
}
