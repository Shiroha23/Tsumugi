import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/empty_state.dart';
import '../../../sources/model/common.dart';
import '../../../sources/registry/providers.dart';
import '../../../sources/repository/providers.dart';
import '../labels.dart';
import 'repository_install_dialog.dart';

/// 浏览一个仓库的源：按类型 / 语言 / NSFW 过滤，安装或更新。
class RepositoryBrowsePage extends ConsumerStatefulWidget {
  const RepositoryBrowsePage({super.key, required this.url});

  /// 仓库地址（[SubscribedRepository.url]）。
  final String url;

  @override
  ConsumerState<RepositoryBrowsePage> createState() =>
      _RepositoryBrowsePageState();
}

class _RepositoryBrowsePageState extends ConsumerState<RepositoryBrowsePage> {
  MediaType? _type;
  String? _lang;
  bool _hideNsfw = false;

  Future<void> _install(
    SubscribedRepository repo,
    RepositoryEntry entry,
  ) async {
    final result = await showRepositoryInstallDialog(
      context,
      repository: repo,
      entry: entry,
    );
    if (result == RepositoryInstallResult.installed && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text('已安装「${entry.name}」${entry.version}')),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final repos = ref.watch(subscribedRepositoriesProvider).value;
    final installed = {
      for (final s
          in ref.watch(installedSourcesProvider()).value ??
              const <InstalledSource>[])
        s.id: s,
    };
    final repo = repos?.where((r) => r.url == widget.url).firstOrNull;
    if (repos == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (repo == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const EmptyState(
          icon: Icons.inventory_2_outlined,
          message: '仓库已退订',
        ),
      );
    }
    final langs = {for (final e in repo.entries) ?e.lang}.toList()..sort();
    final types = {for (final e in repo.entries) e.type};
    // 刷新后索引里可能不再有所选语言：视为“全部语言”，避免无法清除的筛选。
    final lang = langs.contains(_lang) ? _lang : null;
    final visible = [
      for (final e in repo.entries)
        if ((_type == null || e.type == _type) &&
            (lang == null || e.lang == lang) &&
            !(_hideNsfw && e.nsfw))
          e,
    ];

    return Scaffold(
      appBar: AppBar(title: Text(repo.name)),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (repo.lastError != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: RepositoryMessageBox(
                messages: [
                  '上次检查失败：${repo.lastErrorMessage ?? repo.lastError!.name}',
                  if (repo.index != null) '以下为上次成功取得的列表。',
                ],
                error: true,
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                ChoiceChip(
                  label: const Text('全部'),
                  selected: _type == null,
                  onSelected: (_) => setState(() => _type = null),
                ),
                for (final t in MediaType.values)
                  if (types.contains(t))
                    ChoiceChip(
                      label: Text(t.label),
                      selected: _type == t,
                      onSelected: (_) => setState(() => _type = t),
                    ),
                if (langs.isNotEmpty)
                  DropdownButton<String?>(
                    value: lang,
                    hint: const Text('全部语言'),
                    onChanged: (v) => setState(() => _lang = v),
                    items: [
                      const DropdownMenuItem(value: null, child: Text('全部语言')),
                      for (final l in langs)
                        DropdownMenuItem(value: l, child: Text(l)),
                    ],
                  ),
                FilterChip(
                  label: const Text('隐藏 NSFW'),
                  selected: _hideNsfw,
                  onSelected: (v) => setState(() => _hideNsfw = v),
                ),
              ],
            ),
          ),
          const Divider(),
          Expanded(
            child: visible.isEmpty
                ? EmptyState(
                    icon: Icons.extension_outlined,
                    message: repo.index == null ? '无法读取该仓库的索引，请刷新' : '没有符合条件的源',
                  )
                : ListView.builder(
                    itemCount: visible.length,
                    itemBuilder: (context, i) {
                      final e = visible[i];
                      return _EntryTile(
                        entry: e,
                        state: entryState(repo.url, e, installed[e.id]),
                        installedVersion: installed[e.id]?.version,
                        onInstall: () => _install(repo, e),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({
    required this.entry,
    required this.state,
    required this.installedVersion,
    required this.onInstall,
  });

  final RepositoryEntry entry;
  final RepositoryEntryState state;
  final String? installedVersion;
  final VoidCallback onInstall;

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final subtitle = [
      state == RepositoryEntryState.updateAvailable
          ? 'v$installedVersion → v${e.version}'
          : 'v${e.version}',
      e.type.label,
      ?e.lang,
      if (e.nsfw) 'NSFW',
      if (state == RepositoryEntryState.otherOrigin) '已从其他来源安装',
      if (state == RepositoryEntryState.needsClientUpdate) '需要更新客户端',
    ].join(' · ');
    final Widget trailing = switch (state) {
      RepositoryEntryState.notInstalled => FilledButton.tonal(
        onPressed: onInstall,
        child: const Text('安装'),
      ),
      RepositoryEntryState.updateAvailable => FilledButton(
        onPressed: onInstall,
        child: const Text('更新'),
      ),
      RepositoryEntryState.installed => const TextButton(
        onPressed: null,
        child: Text('已安装'),
      ),
      RepositoryEntryState.otherOrigin ||
      RepositoryEntryState.needsClientUpdate => const TextButton(
        onPressed: null,
        child: Text('不可用'),
      ),
    };
    return ListTile(
      key: ValueKey('repo-entry-${e.id}'),
      leading: Icon(e.type.icon),
      title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: trailing,
    );
  }
}
