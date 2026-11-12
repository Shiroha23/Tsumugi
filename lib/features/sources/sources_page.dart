import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/widgets/empty_state.dart';
import '../../sources/model/common.dart';
import '../../sources/registry/providers.dart';
import 'import_source_dialog.dart';
import 'labels.dart';

class SourcesPage extends ConsumerStatefulWidget {
  const SourcesPage({super.key});

  @override
  ConsumerState<SourcesPage> createState() => _SourcesPageState();
}

class _SourcesPageState extends ConsumerState<SourcesPage> {
  /// 拖动排序后、数据库回推新顺序之前的本地顺序，避免列表闪回。
  final _pendingOrder = <MediaType, List<String>>{};

  Future<void> _import() async {
    final installed = await showImportSourceDialog(context);
    if (installed == null || !mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('已安装「${installed.name}」')));
  }

  Future<void> _confirmRemove(InstalledSource source) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除源'),
        content: Text('确定删除「${source.name}」吗？此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(sourceRegistryProvider).remove(source.id);
  }

  void _reorder(MediaType type, List<InstalledSource> group, int from, int to) {
    if (from == to) return;
    final ids = [for (final s in group) s.id];
    ids.insert(to, ids.removeAt(from));
    setState(() => _pendingOrder[type] = ids);
    ref.read(sourceRegistryProvider).reorder(ids);
  }

  List<InstalledSource> _ordered(MediaType type, List<InstalledSource> group) {
    final pending = _pendingOrder[type];
    if (pending == null || pending.length != group.length) return group;
    final byId = {for (final s in group) s.id: s};
    if (!pending.every(byId.containsKey)) return group;
    return [for (final id in pending) byId[id]!];
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(installedSourcesProvider(), (_, next) {
      if (next.hasValue && _pendingOrder.isNotEmpty) {
        setState(_pendingOrder.clear);
      }
    });
    final sources = ref.watch(installedSourcesProvider());
    return Scaffold(
      appBar: AppBar(
        title: const Text('源'),
        actions: [
          IconButton(
            onPressed: _import,
            tooltip: '导入源',
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: switch (sources) {
        AsyncValue(:final value?) when value.isEmpty => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const EmptyState(
                icon: Icons.extension_outlined,
                message: '还没有安装任何源',
              ),
              FilledButton.icon(
                onPressed: _import,
                icon: const Icon(Icons.add),
                label: const Text('导入源'),
              ),
            ],
          ),
        ),
        AsyncValue(:final value?) => _buildList(value),
        AsyncValue(:final error?) => EmptyState(
          icon: Icons.error_outline,
          message: '读取已安装的源失败：$error',
        ),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }

  Widget _buildList(List<InstalledSource> all) {
    final groups = {
      for (final type in MediaType.values)
        type: [
          for (final s in all)
            if (s.type == type) s,
        ],
    }..removeWhere((_, list) => list.isEmpty);

    return CustomScrollView(
      slivers: [
        for (final MapEntry(key: type, value: raw) in groups.entries) ...[
          SliverToBoxAdapter(
            child: _GroupHeader(type: type, count: raw.length),
          ),
          _buildGroup(type, _ordered(type, raw)),
        ],
        const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
      ],
    );
  }

  Widget _buildGroup(MediaType type, List<InstalledSource> group) {
    return SliverReorderableList(
      itemCount: group.length,
      onReorderItem: (from, to) => _reorder(type, group, from, to),
      proxyDecorator: (child, _, _) => Material(elevation: 4, child: child),
      itemBuilder: (context, i) {
        final s = group[i];
        return _SourceTile(
          key: ValueKey(s.id),
          index: i,
          source: s,
          onEnabledChanged: (v) =>
              ref.read(sourceRegistryProvider).setEnabled(s.id, v),
          onRemove: () => _confirmRemove(s),
        );
      },
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.type, required this.count});

  final MediaType type;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        '${type.label}（$count）',
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}

class _SourceTile extends StatelessWidget {
  const _SourceTile({
    super.key,
    required this.index,
    required this.source,
    required this.onEnabledChanged,
    required this.onRemove,
  });

  final int index;
  final InstalledSource source;
  final ValueChanged<bool> onEnabledChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m = source.manifest;
    final host = m == null ? null : Uri.tryParse(m.baseUrl)?.host;
    final subtitle =
        source.loadError ??
        [
          'v${source.version}',
          if (m != null) m.engine.label,
          if (host != null && host.isNotEmpty) host,
          if (m?.nsfw ?? false) 'NSFW',
        ].join(' · ');

    return Material(
      type: MaterialType.transparency,
      child: ListTile(
        leading: Icon(
          m == null ? Icons.error_outline : source.type.icon,
          color: m == null ? theme.colorScheme.error : null,
        ),
        title: Text(source.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          subtitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: m == null ? TextStyle(color: theme.colorScheme.error) : null,
        ),
        enabled: source.enabled,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Switch(
              value: source.enabled,
              onChanged: m == null ? null : onEnabledChanged,
            ),
            IconButton(
              onPressed: onRemove,
              tooltip: '删除',
              icon: const Icon(Icons.delete_outline),
            ),
            ReorderableDragStartListener(
              index: index,
              child: const Padding(
                padding: EdgeInsets.all(8),
                child: Icon(Icons.drag_handle),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
