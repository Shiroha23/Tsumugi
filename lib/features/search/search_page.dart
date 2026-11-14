import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../shared/image/source_image.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/source_error_view.dart';
import '../../sources/model/common.dart';
import '../comic/detail/comic_routes.dart';
import '../novel/novel_routes.dart';
import '../sources/labels.dart';
import '../video/video_routes.dart';
import 'search_controller.dart';

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _submit() =>
      ref.read(sourceSearchControllerProvider.notifier).search(_text.text);

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(sourceSearchControllerProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('搜索')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              controller: _text,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                hintText: '输入关键词',
                prefixIcon: const Icon(Icons.search),
                border: const OutlineInputBorder(),
                isDense: true,
                suffixIcon: IconButton(
                  tooltip: '搜索',
                  icon: const Icon(Icons.arrow_forward),
                  onPressed: _submit,
                ),
              ),
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                for (final t in MediaType.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(t.label),
                      selected: state.type == t,
                      onSelected: (_) => ref
                          .read(sourceSearchControllerProvider.notifier)
                          .setType(t),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(child: _Results(state: state)),
        ],
      ),
    );
  }
}

class _Results extends StatelessWidget {
  const _Results({required this.state});

  final SearchState state;

  @override
  Widget build(BuildContext context) {
    if (!state.started) {
      return const EmptyState(
        icon: Icons.search_outlined,
        message: '输入关键词，在所有已启用的源中搜索',
      );
    }
    if (state.groups.isEmpty) {
      return EmptyState(
        icon: Icons.extension_off_outlined,
        message: '没有已启用的${state.type.label}源\n先在「源」页面导入并启用',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: state.groups.length,
      itemBuilder: (context, i) =>
          _GroupSection(group: state.groups[i], type: state.type),
    );
  }
}

class _GroupSection extends ConsumerWidget {
  const _GroupSection({required this.group, required this.type});

  final SourceSearchGroup group;
  final MediaType type;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final error = group.error;
    void loadMore() => ref
        .read(sourceSearchControllerProvider.notifier)
        .loadMore(group.sourceId);

    final Widget status;
    if (group.loading) {
      status = const SizedBox.square(
        dimension: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else if (error != null && group.items.isEmpty) {
      status = Icon(
        Icons.error_outline,
        size: 18,
        color: theme.colorScheme.error,
      );
    } else {
      status = Text(
        '${group.items.length}${group.hasMore ? '+' : ''} 条',
        style: theme.textTheme.labelMedium,
      );
    }

    return Column(
      key: ValueKey('search-group-${group.sourceId}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  group.sourceName,
                  style: theme.textTheme.titleSmall,
                ),
              ),
              status,
            ],
          ),
        ),
        for (final item in group.items)
          _ResultTile(sourceId: group.sourceId, item: item, type: type),
        if (error != null)
          SourceErrorView(
            error: error,
            sourceId: group.sourceId,
            onRetry: loadMore,
            compact: true,
          )
        else if (!group.loading && group.page > 0 && group.items.isEmpty)
          const ListTile(dense: true, title: Text('没有结果')),
        if (group.loading && group.items.isNotEmpty)
          const Padding(
            padding: EdgeInsets.all(8),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (!group.loading && error == null && group.hasMore)
          Align(
            child: TextButton(onPressed: loadMore, child: const Text('加载更多')),
          ),
        const Divider(height: 1),
      ],
    );
  }
}

class _ResultTile extends StatelessWidget {
  const _ResultTile({
    required this.sourceId,
    required this.item,
    required this.type,
  });

  final String sourceId;
  final SearchItem item;
  final MediaType type;

  void _open(BuildContext context) {
    switch (type) {
      case MediaType.comic:
        context.push(ComicRoutes.detail(sourceId, item.id), extra: item);
      case MediaType.novel:
        context.push(NovelRoutes.detail(sourceId, item.id), extra: item);
      case MediaType.video:
        context.push(VideoRoutes.detail(sourceId, item.id), extra: item);
      case MediaType.music:
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('${type.label}详情页尚未实现')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final subtitle = [
      ?item.subtitle,
      if (item.tags.isNotEmpty) item.tags.join(' · '),
    ].join('\n');
    return ListTile(
      leading: CoverImage(
        sourceId: sourceId,
        url: item.cover,
        headers: item.coverHeaders,
        width: 44,
        aspectRatio: 44 / 60,
      ),
      title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: subtitle.isEmpty
          ? null
          : Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
      onTap: () => _open(context),
    );
  }
}
