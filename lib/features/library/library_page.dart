import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/history/providers.dart';
import '../../shared/library/providers.dart';
import '../../shared/widgets/empty_state.dart';
import '../../sources/model/common.dart';
import '../sources/labels.dart';
import 'cover_image.dart';
import 'open_item.dart';

/// 书架页：“书架”与“历史”两个标签。
class LibraryPage extends StatelessWidget {
  const LibraryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('书架'),
          actions: const [_ClearHistoryButton()],
          bottom: const TabBar(
            tabs: [
              Tab(text: '书架'),
              Tab(text: '历史'),
            ],
          ),
        ),
        body: const TabBarView(children: [_ShelfTab(), _HistoryTab()]),
      ),
    );
  }
}

void _open(
  BuildContext context,
  WidgetRef ref,
  LibraryItem item, {
  ItemProgress? progress,
}) {
  final open = ref.read(openItemProvider);
  if (open == null) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('详情页暂不可用')));
    return;
  }
  open(context, item, progress: progress);
}

class _ShelfTab extends ConsumerStatefulWidget {
  const _ShelfTab();

  @override
  ConsumerState<_ShelfTab> createState() => _ShelfTabState();
}

class _ShelfTabState extends ConsumerState<_ShelfTab>
    with AutomaticKeepAliveClientMixin {
  /// null 为全部类型。
  MediaType? _type;

  @override
  bool get wantKeepAlive => true;

  Future<void> _confirmRemove(LibraryEntry entry) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移出书架'),
        content: Text('确定把「${entry.item.title}」移出书架吗？阅读进度会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('移出'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref
        .read(libraryRepositoryProvider)
        .remove(entry.sourceId, entry.itemId);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('已移出「${entry.item.title}」')));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final entries = ref.watch(libraryEntriesProvider(type: _type));
    return Column(
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            spacing: 8,
            children: [
              for (final type in <MediaType?>[null, ...MediaType.values])
                ChoiceChip(
                  label: Text(type?.label ?? '全部'),
                  selected: _type == type,
                  onSelected: (_) => setState(() => _type = type),
                ),
            ],
          ),
        ),
        Expanded(
          child: switch (entries) {
            AsyncData(:final value) when value.isEmpty => EmptyState(
              icon: Icons.collections_bookmark_outlined,
              message: _type == null ? '书架是空的' : '书架里还没有${_type!.label}',
            ),
            AsyncData(:final value) => GridView.builder(
              padding: const EdgeInsets.all(16),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 150,
                childAspectRatio: 0.58,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
              ),
              itemCount: value.length,
              itemBuilder: (context, i) => _ShelfTile(
                entry: value[i],
                onTap: () => _open(context, ref, value[i].item),
                onLongPress: () => _confirmRemove(value[i]),
              ),
            ),
            AsyncError(:final error) => EmptyState(
              icon: Icons.error_outline,
              message: '书架加载失败：$error',
            ),
            _ => const Center(child: CircularProgressIndicator()),
          },
        ),
      ],
    );
  }
}

class _ShelfTile extends StatelessWidget {
  const _ShelfTile({
    required this.entry,
    required this.onTap,
    required this.onLongPress,
  });

  final LibraryEntry entry;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final item = entry.item;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      onLongPress: onLongPress,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CoverImage(url: item.cover, headers: item.coverHeaders),
          const SizedBox(height: 6),
          Text(
            item.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }
}

class _HistoryTab extends ConsumerWidget {
  const _HistoryTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(recentHistoryProvider());
    return switch (history) {
      AsyncData(:final value) when value.isEmpty => const EmptyState(
        icon: Icons.history,
        message: '还没有阅读记录',
      ),
      AsyncData(:final value) => ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: value.length,
        itemBuilder: (context, i) {
          final p = value[i];
          return ListTile(
            leading: SizedBox(
              width: 42,
              child: CoverImage(
                url: p.item.cover,
                headers: p.item.coverHeaders,
              ),
            ),
            title: Text(
              p.item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '${progressLabel(p)} · ${relativeTime(p.updatedAt, DateTime.now())}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: IconButton(
              tooltip: '删除记录',
              icon: const Icon(Icons.close),
              onPressed: () => ref
                  .read(historyRepositoryProvider)
                  .removeHistory(p.sourceId, p.itemId),
            ),
            onTap: () => _open(context, ref, p.item, progress: p),
          );
        },
      ),
      AsyncError(:final error) => EmptyState(
        icon: Icons.error_outline,
        message: '历史加载失败：$error',
      ),
      _ => const Center(child: CircularProgressIndicator()),
    };
  }
}

/// 只在“历史”标签可见的“清空历史”按钮。
class _ClearHistoryButton extends ConsumerStatefulWidget {
  const _ClearHistoryButton();

  @override
  ConsumerState<_ClearHistoryButton> createState() =>
      _ClearHistoryButtonState();
}

class _ClearHistoryButtonState extends ConsumerState<_ClearHistoryButton> {
  TabController? _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = DefaultTabController.of(context);
    if (controller == _controller) return;
    _controller?.removeListener(_onTab);
    _controller = controller..addListener(_onTab);
  }

  @override
  void dispose() {
    _controller?.removeListener(_onTab);
    super.dispose();
  }

  void _onTab() => setState(() {});

  Future<void> _confirm() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空历史'),
        content: const Text('确定清空全部阅读历史与进度吗？此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok == true) await ref.read(historyRepositoryProvider).clearHistory();
  }

  @override
  Widget build(BuildContext context) {
    if (_controller?.index != 1) return const SizedBox.shrink();
    return IconButton(
      tooltip: '清空历史',
      icon: const Icon(Icons.delete_sweep_outlined),
      onPressed: _confirm,
    );
  }
}

/// 历史中的进度描述，例如“第 3 话 · 第 12/20 页”。
String progressLabel(ItemProgress p) {
  final page = p.page;
  if (page == null) return p.unitTitle;
  final count = p.pageCount;
  return count == null
      ? '${p.unitTitle} · 第 ${page + 1} 页'
      : '${p.unitTitle} · 第 ${page + 1}/$count 页';
}

/// 粗粒度相对时间：刚刚 / N 分钟前 / N 小时前 / N 天前 / 日期。
String relativeTime(DateTime time, DateTime now) {
  final d = now.difference(time);
  if (d.inMinutes < 1) return '刚刚';
  if (d.inHours < 1) return '${d.inMinutes} 分钟前';
  if (d.inDays < 1) return '${d.inHours} 小时前';
  if (d.inDays < 7) return '${d.inDays} 天前';
  final t = time.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)}';
}
