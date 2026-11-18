import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/empty_state.dart';
import '../../../sources/repository/providers.dart';
import 'repository_browse_page.dart';
import 'repository_install_dialog.dart';

/// 规则仓库列表：添加、检查更新（下拉刷新 / 按钮）、退订、「全部更新」（architecture §4.4）。
class RepositoriesPage extends ConsumerStatefulWidget {
  const RepositoriesPage({super.key});

  @override
  ConsumerState<RepositoriesPage> createState() => _RepositoriesPageState();
}

class _RepositoriesPageState extends ConsumerState<RepositoriesPage> {
  final _refreshKey = GlobalKey<RefreshIndicatorState>();
  bool _updating = false;

  RepositoryService get _service => ref.read(repositoryServiceProvider);

  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _add() async {
    final added = await showDialog<SubscribedRepository>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AddRepositoryDialog(),
    );
    if (added != null && mounted) _showSnack('已订阅「${added.name}」');
  }

  Future<void> _refresh() => _service.refreshAll();

  Future<void> _confirmUnsubscribe(SubscribedRepository repo) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('退订仓库'),
        content: Text('确定退订「${repo.name}」吗？已安装的源会保留，但不再检查更新。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('退订'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _service.unsubscribe(repo.url);
    if (mounted) _showSnack('已退订「${repo.name}」');
  }

  /// 逐个弹出预览，不批量跳过确认。
  Future<void> _updateAll(List<SourceUpdateAvailable> updates) async {
    setState(() => _updating = true);
    var done = 0;
    try {
      for (var i = 0; i < updates.length; i++) {
        if (!mounted) return;
        final u = updates[i];
        final result = await showRepositoryInstallDialog(
          context,
          repository: u.repository,
          entry: u.entry,
          position: '${i + 1} / ${updates.length}',
        );
        if (result == RepositoryInstallResult.installed) done++;
        if (result == RepositoryInstallResult.stopped) break;
      }
    } finally {
      if (mounted) setState(() => _updating = false);
    }
    if (mounted) _showSnack('已更新 $done 个源');
  }

  @override
  Widget build(BuildContext context) {
    final repos = ref.watch(subscribedRepositoriesProvider);
    final updates = [
      for (final s in ref.watch(sourceRepositoryStatusProvider).values)
        if (s is SourceUpdateAvailable) s,
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text('规则仓库'),
        actions: [
          IconButton(
            onPressed: () => _refreshKey.currentState?.show(),
            tooltip: '检查更新',
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            onPressed: _add,
            tooltip: '添加仓库',
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: RefreshIndicator(
        key: _refreshKey,
        onRefresh: _refresh,
        child: switch (repos) {
          AsyncValue(:final value?) when value.isEmpty => ListView(
            children: [
              const SizedBox(height: 80),
              const EmptyState(
                icon: Icons.inventory_2_outlined,
                message: '还没有订阅任何仓库\n仓库只是分发渠道，只订阅你信任的仓库',
              ),
              Center(
                child: FilledButton.icon(
                  onPressed: _add,
                  icon: const Icon(Icons.add),
                  label: const Text('添加仓库'),
                ),
              ),
            ],
          ),
          AsyncValue(:final value?) => ListView(
            children: [
              if (updates.isNotEmpty)
                Card(
                  margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: ListTile(
                    leading: const Icon(Icons.system_update_alt),
                    title: Text('${updates.length} 个源可更新'),
                    trailing: FilledButton(
                      onPressed: _updating ? null : () => _updateAll(updates),
                      child: const Text('全部更新'),
                    ),
                  ),
                ),
              for (final repo in value)
                _RepositoryTile(
                  repository: repo,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => RepositoryBrowsePage(url: repo.url),
                    ),
                  ),
                  onUnsubscribe: () => _confirmUnsubscribe(repo),
                ),
            ],
          ),
          AsyncValue(:final error?) => ListView(
            children: [
              EmptyState(icon: Icons.error_outline, message: '读取仓库失败：$error'),
            ],
          ),
          _ => const Center(child: CircularProgressIndicator()),
        },
      ),
    );
  }
}

class _RepositoryTile extends StatelessWidget {
  const _RepositoryTile({
    required this.repository,
    required this.onTap,
    required this.onUnsubscribe,
  });

  final SubscribedRepository repository;
  final VoidCallback onTap;
  final VoidCallback onUnsubscribe;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = repository;
    final checked = r.lastCheckedAt;
    final status = r.lastError != null
        ? '检查失败：${r.lastErrorMessage ?? r.lastError!.name}'
        : checked == null
        ? '尚未检查'
        : '上次检查 ${_formatTime(checked.toLocal())}';
    return ListTile(
      leading: Icon(
        r.lastError == null ? Icons.inventory_2_outlined : Icons.error_outline,
        color: r.lastError == null ? null : theme.colorScheme.error,
      ),
      title: Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${r.url}\n${r.entries.length} 个源 · $status',
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
      isThreeLine: true,
      onTap: onTap,
      trailing: PopupMenuButton<void>(
        tooltip: '仓库菜单',
        itemBuilder: (context) => [
          PopupMenuItem(
            onTap: onUnsubscribe,
            child: const ListTile(
              leading: Icon(Icons.delete_outline),
              title: Text('退订'),
            ),
          ),
        ],
      ),
    );
  }
}

String _formatTime(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

/// 添加仓库：输入地址 → 取索引 → 展示仓库名与源数量 → 确认订阅。
class AddRepositoryDialog extends ConsumerStatefulWidget {
  const AddRepositoryDialog({super.key});

  @override
  ConsumerState<AddRepositoryDialog> createState() =>
      _AddRepositoryDialogState();
}

class _AddRepositoryDialogState extends ConsumerState<AddRepositoryDialog> {
  final _url = TextEditingController();
  RepositoryIndex? _index;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on RepositoryException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _fetch() => _run(() async {
    final input = _url.text.trim();
    if (input.isEmpty) {
      setState(() => _error = '请输入仓库地址');
      return;
    }
    final index = await ref.read(repositoryServiceProvider).fetchIndex(input);
    if (mounted) setState(() => _index = index);
  });

  void _subscribe() => _run(() async {
    final repo = await ref.read(repositoryServiceProvider).subscribe(_index!);
    if (mounted) Navigator.of(context).pop(repo);
  });

  @override
  Widget build(BuildContext context) {
    final index = _index;
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(index == null ? '添加仓库' : '订阅仓库'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (index == null) ...[
              TextField(
                controller: _url,
                enabled: !_busy,
                autofocus: true,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: '仓库地址',
                  hintText: 'https://example.com/index.json',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _busy ? null : _fetch(),
              ),
              const SizedBox(height: 8),
              Text(
                '仓库只是分发渠道：源的能力仍受沙箱与主机白名单限制，安装与更新前都会让你确认。只订阅你信任的仓库。',
                style: theme.textTheme.bodySmall,
              ),
            ] else ...[
              Text(index.name, style: theme.textTheme.titleLarge),
              const SizedBox(height: 8),
              SelectableText(index.url.toString()),
              const SizedBox(height: 8),
              Text('共 ${index.entries.length} 个源'),
            ],
            if (_busy) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
            ],
            if (_error case final e?) ...[
              const SizedBox(height: 12),
              RepositoryMessageBox(messages: [e], error: true),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _busy ? null : (index == null ? _fetch : _subscribe),
          child: Text(index == null ? '下一步' : '订阅'),
        ),
      ],
    );
  }
}
