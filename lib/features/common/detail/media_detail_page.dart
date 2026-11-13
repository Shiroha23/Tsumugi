import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/history/providers.dart';
import '../../../shared/image/source_image.dart';
import '../../../shared/library/providers.dart';
import '../../../shared/widgets/source_error_view.dart';
import '../../../sources/model/common.dart';
import '../../../sources/runtime/source_runtime.dart';
import '../reading_order.dart';
import 'media_detail_provider.dart';

/// 由章节 id 得到阅读器地址。[resume] 为该章节的最新进度（从“上次读到”的章节继续时），否则为 null。
typedef ReaderLocationBuilder = String Function(
  String unitId,
  ItemProgress? resume,
);

/// 作品详情（漫画 / 小说共用）：封面、标题、作者、简介、标签、状态、章节列表（多线路、正序 / 倒序）、
/// 加入书架、继续 / 开始阅读、已读与“上次读到”标记。
class MediaDetailPage extends ConsumerStatefulWidget {
  const MediaDetailPage({
    super.key,
    required this.sourceId,
    required this.itemId,
    required this.mediaType,
    required this.readerLocation,
    required this.progressLabel,
    this.preview,
  });

  final String sourceId;
  final String itemId;
  final MediaType mediaType;
  final ReaderLocationBuilder readerLocation;

  /// “上次读到”的说明文字。
  final String Function(ItemProgress progress) progressLabel;

  /// 从搜索结果进入时带上的条目，用于加载期间先显示标题，并提供封面 headers。
  final SearchItem? preview;

  @override
  ConsumerState<MediaDetailPage> createState() => _MediaDetailPageState();
}

class _MediaDetailPageState extends ConsumerState<MediaDetailPage> {
  int _group = 0;
  bool _descending = false;

  void _retry() {
    // 源实例创建失败的结果也被 provider 缓存着，重试时一并清掉。
    ref.invalidate(sourceInstanceProvider(widget.sourceId));
    ref.invalidate(mediaDetailProvider(widget.sourceId, widget.itemId));
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(
      mediaDetailProvider(widget.sourceId, widget.itemId),
    );
    final title = async.value?.detail.title ?? widget.preview?.title ?? '';
    return Scaffold(
      body: switch (async) {
        AsyncData(:final value) => _buildDetail(context, value),
        AsyncError(:final error) => _Bare(
          title: title,
          child: SourceErrorView(
            error: error,
            sourceId: widget.sourceId,
            onRetry: _retry,
          ),
        ),
        _ => _Bare(
          title: title,
          child: const Center(child: CircularProgressIndicator()),
        ),
      },
    );
  }

  Widget _buildDetail(BuildContext context, MediaDetailData data) {
    final detail = data.detail;
    final groups = _groupsOf(detail);
    final index = _group.clamp(0, groups.length - 1);
    final units = groups.isEmpty ? const <Unit>[] : groups[index].units;
    final ordered = _descending ? units.reversed.toList() : units;
    final readUnits =
        ref.watch(readUnitIdsProvider(widget.sourceId, widget.itemId)).value ??
        const <String>{};
    final progress = ref
        .watch(itemProgressProvider(widget.sourceId, widget.itemId))
        .value;
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
          child: _Header(
            sourceId: widget.sourceId,
            itemId: widget.itemId,
            detail: detail,
            coverHeaders: coverHeaders,
            actions: _Actions(
              sourceId: widget.sourceId,
              itemId: widget.itemId,
              detail: detail,
              coverHeaders: coverHeaders,
              mediaType: widget.mediaType,
              readerLocation: widget.readerLocation,
              progressLabel: widget.progressLabel,
            ),
          ),
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
              final read = readUnits.contains(unit.id);
              final current = progress?.unitId == unit.id;
              final muted = Theme.of(context).colorScheme.onSurfaceVariant;
              return ListTile(
                title: Text(
                  unit.title,
                  style: read && !current ? TextStyle(color: muted) : null,
                ),
                subtitle: unit.updatedAt == null ? null : Text(unit.updatedAt!),
                trailing: current
                    ? const Icon(Icons.bookmark, semanticLabel: '上次读到')
                    : read
                    ? Icon(Icons.check, color: muted, semanticLabel: '已读')
                    : null,
                // 打开上次读到的章节时从记录的页码继续。
                onTap: () => context.push(
                  widget.readerLocation(unit.id, current ? progress : null),
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
  const _Header({
    required this.sourceId,
    required this.itemId,
    required this.detail,
    required this.coverHeaders,
    required this.actions,
  });

  final String sourceId;
  final String itemId;
  final Detail detail;
  final Headers? coverHeaders;
  final Widget actions;

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
                sourceId: widget.sourceId,
                url: detail.cover,
                headers: widget.coverHeaders,
                width: 112,
                aspectRatio: 112 / 156,
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
          widget.actions,
        ],
      ),
    );
  }
}

/// 书架与阅读入口：加入 / 移出书架；有进度时“继续阅读”，否则从第一章“开始阅读”。
class _Actions extends ConsumerWidget {
  const _Actions({
    required this.sourceId,
    required this.itemId,
    required this.detail,
    required this.coverHeaders,
    required this.mediaType,
    required this.readerLocation,
    required this.progressLabel,
  });

  final String sourceId;
  final String itemId;
  final Detail detail;
  final Headers? coverHeaders;
  final MediaType mediaType;
  final ReaderLocationBuilder readerLocation;
  final String Function(ItemProgress progress) progressLabel;

  LibraryItem get _item => LibraryItem(
    sourceId: sourceId,
    itemId: itemId,
    title: detail.title,
    mediaType: mediaType,
    cover: detail.cover,
    coverHeaders: coverHeaders,
  );

  Future<void> _toggleLibrary(WidgetRef ref, bool inLibrary) async {
    final repo = ref.read(libraryRepositoryProvider);
    if (inLibrary) {
      await repo.remove(sourceId, itemId);
    } else {
      await repo.add(_item);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final inLibraryAsync = ref.watch(isInLibraryProvider(sourceId, itemId));
    final inLibrary = inLibraryAsync.value ?? false;
    final progress = ref.watch(itemProgressProvider(sourceId, itemId)).value;
    final first = readingOrder(detail).firstOrNull;
    final muted = TextStyle(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );

    final VoidCallback? read = switch ((progress, first)) {
      (final p?, _) => () => context.push(readerLocation(p.unitId, p)),
      (null, final u?) => () => context.push(readerLocation(u.id, null)),
      _ => null,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              icon: Icon(
                inLibrary ? Icons.bookmark : Icons.bookmark_add_outlined,
              ),
              label: Text(inLibrary ? '已在书架' : '加入书架'),
              onPressed: inLibraryAsync.hasValue
                  ? () => _toggleLibrary(ref, inLibrary)
                  : null,
            ),
            FilledButton.icon(
              icon: const Icon(Icons.menu_book),
              label: Text(progress != null ? '继续阅读' : '开始阅读'),
              onPressed: read,
            ),
          ],
        ),
        if (progress != null) ...[
          const SizedBox(height: 6),
          Text(
            progressLabel(progress),
            style: muted,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ],
    );
  }
}
