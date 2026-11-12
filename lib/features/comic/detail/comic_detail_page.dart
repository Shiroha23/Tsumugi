import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/widgets/cover_image.dart';
import '../../../shared/widgets/source_error_view.dart';
import '../../../sources/model/common.dart';
import '../../../sources/runtime/source_runtime.dart';
import 'comic_detail_provider.dart';
import 'comic_routes.dart';

/// 漫画详情：封面、标题、作者、简介、标签、状态、章节列表（多线路、正序 / 倒序）。
class ComicDetailPage extends ConsumerStatefulWidget {
  const ComicDetailPage({
    super.key,
    required this.sourceId,
    required this.itemId,
    this.preview,
  });

  final String sourceId;
  final String itemId;

  /// 从搜索结果进入时带上的条目，用于加载期间先显示标题，并提供封面 headers。
  final SearchItem? preview;

  @override
  ConsumerState<ComicDetailPage> createState() => _ComicDetailPageState();
}

class _ComicDetailPageState extends ConsumerState<ComicDetailPage> {
  int _group = 0;
  bool _descending = false;

  void _retry() {
    // 源实例创建失败的结果也被 provider 缓存着，重试时一并清掉。
    ref.invalidate(sourceInstanceProvider(widget.sourceId));
    ref.invalidate(comicDetailProvider(widget.sourceId, widget.itemId));
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(
      comicDetailProvider(widget.sourceId, widget.itemId),
    );
    final title = async.value?.detail.title ?? widget.preview?.title ?? '';
    return Scaffold(
      body: switch (async) {
        AsyncData(:final value) => _buildDetail(context, value),
        AsyncError(:final error) => _Bare(
          title: title,
          child: SourceErrorView(error: error, onRetry: _retry),
        ),
        _ => _Bare(
          title: title,
          child: const Center(child: CircularProgressIndicator()),
        ),
      },
    );
  }

  Widget _buildDetail(BuildContext context, ComicDetailData data) {
    final detail = data.detail;
    final groups = _groupsOf(detail);
    final index = _group.clamp(0, groups.length - 1);
    final units = groups.isEmpty ? const <Unit>[] : groups[index].units;
    final ordered = _descending ? units.reversed.toList() : units;
    final preview = widget.preview;
    final coverHeaders =
        preview != null &&
            preview.cover == detail.cover &&
            preview.coverHeaders != null
        ? preview.coverHeaders
        : data.sourceHeaders;

    return CustomScrollView(
      slivers: [
        SliverAppBar(pinned: true, title: Text(detail.title)),
        SliverToBoxAdapter(
          child: _Header(detail: detail, coverHeaders: coverHeaders),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 8, 4),
            child: Row(
              children: [
                Text(
                  '章节（${units.length}）',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                TextButton.icon(
                  icon: const Icon(Icons.swap_vert),
                  label: Text(_descending ? '倒序' : '正序'),
                  onPressed: () => setState(() => _descending = !_descending),
                ),
              ],
            ),
          ),
        ),
        if (groups.length > 1)
          SliverToBoxAdapter(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  for (final (i, g) in groups.indexed)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(g.name),
                        selected: i == index,
                        onSelected: (_) => setState(() => _group = i),
                      ),
                    ),
                ],
              ),
            ),
          ),
        if (ordered.isEmpty)
          const SliverToBoxAdapter(child: ListTile(title: Text('没有章节')))
        else
          SliverList.builder(
            itemCount: ordered.length,
            itemBuilder: (context, i) {
              final unit = ordered[i];
              return ListTile(
                title: Text(unit.title),
                subtitle: unit.updatedAt == null ? null : Text(unit.updatedAt!),
                onTap: () => context.push(
                  ComicRoutes.reader(widget.sourceId, widget.itemId, unit.id),
                ),
              );
            },
          ),
        const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
      ],
    );
  }

  /// 有 `groups`（多线路）时按线路展示，否则把 `units` 视为唯一一组。
  static List<UnitGroup> _groupsOf(Detail detail) {
    final groups = detail.groups;
    if (groups != null && groups.isNotEmpty) return groups;
    return [UnitGroup(name: '默认', units: detail.units)];
  }
}

/// 加载中 / 出错时的页面骨架。
class _Bare extends StatelessWidget {
  const _Bare({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      AppBar(title: Text(title)),
      Expanded(child: child),
    ],
  );
}

class _Header extends StatefulWidget {
  const _Header({required this.detail, required this.coverHeaders});

  final Detail detail;
  final Headers? coverHeaders;

  @override
  State<_Header> createState() => _HeaderState();
}

class _HeaderState extends State<_Header> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final detail = widget.detail;
    final theme = Theme.of(context);
    final muted = TextStyle(color: theme.colorScheme.onSurfaceVariant);
    final status = switch (detail.status) {
      SeriesStatus.ongoing => '连载中',
      SeriesStatus.completed => '已完结',
      SeriesStatus.unknown => null,
    };
    final description = detail.description?.trim();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CoverImage(
                url: detail.cover,
                headers: widget.coverHeaders,
                width: 112,
                height: 156,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SelectableText(
                      detail.title,
                      style: theme.textTheme.titleLarge,
                    ),
                    if (detail.author case final author?) ...[
                      const SizedBox(height: 4),
                      Text(author, style: muted),
                    ],
                    if (status != null) ...[
                      const SizedBox(height: 8),
                      Chip(
                        label: Text(status),
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                    if (detail.updatedAt case final updated?) ...[
                      const SizedBox(height: 4),
                      Text('更新于 $updated', style: muted),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (detail.tags.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final t in detail.tags)
                  Chip(label: Text(t), visualDensity: VisualDensity.compact),
              ],
            ),
          ],
          if (description != null && description.isNotEmpty) ...[
            const SizedBox(height: 12),
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Text(
                description,
                maxLines: _expanded ? null : 4,
                overflow: _expanded ? null : TextOverflow.ellipsis,
              ),
            ),
          ],
          const SizedBox(height: 12),
          const Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              // TODO(m2-integration): 接入书架会话的仓库后启用：加入 / 移出书架。
              OutlinedButton(onPressed: null, child: Text('加入书架')),
              // TODO(m2-integration): 按阅读进度跳到上次阅读的章节。
              FilledButton(onPressed: null, child: Text('继续阅读')),
            ],
          ),
        ],
      ),
    );
  }
}
