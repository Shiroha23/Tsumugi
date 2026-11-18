import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../sources/registry/providers.dart';
import '../../../sources/repository/providers.dart';
import '../labels.dart';

/// 从仓库安装 / 更新一个源的结果。
enum RepositoryInstallResult {
  /// 已安装或更新。
  installed,

  /// 用户取消（“全部更新”中为跳过这一个）。
  skipped,

  /// “全部更新”中用户选择停止。
  stopped,
}

/// 下载并校验清单 → 预览（访问的主机；更新时新增的主机单独高亮）→ 安装。
///
/// 新增主机时，点「更新」后还要在第二个对话框中确认一次（architecture §4.4）。
/// [batch] 为「全部更新」中的第 [position] 个，此时额外提供「停止」。
Future<RepositoryInstallResult> showRepositoryInstallDialog(
  BuildContext context, {
  required SubscribedRepository repository,
  required RepositoryEntry entry,
  String? position,
}) async =>
    await showDialog<RepositoryInstallResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => RepositoryInstallDialog(
        repository: repository,
        entry: entry,
        position: position,
      ),
    ) ??
    RepositoryInstallResult.skipped;

class RepositoryInstallDialog extends ConsumerStatefulWidget {
  const RepositoryInstallDialog({
    super.key,
    required this.repository,
    required this.entry,
    this.position,
  });

  final SubscribedRepository repository;
  final RepositoryEntry entry;
  final String? position;

  @override
  ConsumerState<RepositoryInstallDialog> createState() =>
      _RepositoryInstallDialogState();
}

class _RepositoryInstallDialogState
    extends ConsumerState<RepositoryInstallDialog> {
  ImportPreview? _preview;
  List<String>? _errors;
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final preview = await ref
          .read(repositoryServiceProvider)
          .prepareInstall(widget.repository, widget.entry);
      if (mounted) setState(() => _preview = preview);
    } on RepositoryException catch (e) {
      if (mounted) setState(() => _errors = [e.message]);
    } on SourceImportException catch (e) {
      if (mounted) setState(() => _errors = e.messages);
    } catch (e) {
      if (mounted) setState(() => _errors = ['$e']);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _install() async {
    final preview = _preview!;
    if (preview.newHosts.isNotEmpty && !await _confirmNewHosts(preview)) {
      return;
    }
    setState(() {
      _busy = true;
      _errors = null;
    });
    try {
      await ref.read(sourceRegistryProvider).install(preview);
      if (mounted) Navigator.of(context).pop(RepositoryInstallResult.installed);
    } on SourceImportException catch (e) {
      if (mounted) setState(() => _errors = e.messages);
    } catch (e) {
      if (mounted) setState(() => _errors = ['$e']);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirmNewHosts(ImportPreview preview) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认新增的主机'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('更新后「${preview.manifest.name}」将开始访问以下新的主机：'),
            const SizedBox(height: 8),
            for (final h in preview.newHosts)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: SelectableText(
                  h,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            const SizedBox(height: 8),
            const Text('只有在你信任这些主机时才继续。'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确认并更新'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    final upgrade = preview?.existing != null;
    final title = upgrade ? '更新源' : '安装源';
    return AlertDialog(
      title: Text(
        widget.position == null ? title : '$title（${widget.position}）',
      ),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (preview != null)
                ..._previewBody(preview)
              else if (_busy)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                ),
              if (_errors case final errors?) ...[
                const SizedBox(height: 12),
                RepositoryMessageBox(messages: errors, error: true),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (widget.position != null)
          TextButton(
            onPressed: _busy
                ? null
                : () =>
                      Navigator.of(context)
                          .pop(RepositoryInstallResult.stopped),
            child: const Text('停止'),
          ),
        TextButton(
          onPressed: _busy
              ? null
              : () =>
                    Navigator.of(context).pop(RepositoryInstallResult.skipped),
          child: Text(widget.position == null ? '取消' : '跳过'),
        ),
        if (preview != null)
          FilledButton(
            onPressed: _busy ? null : _install,
            child: Text(upgrade ? '更新' : '安装'),
          ),
      ],
    );
  }

  List<Widget> _previewBody(ImportPreview p) {
    final m = p.manifest;
    final theme = Theme.of(context);
    final newHosts = p.newHosts.toSet();
    final version = p.existing == null
        ? m.version
        : '${p.existing!.version} → ${m.version}';
    return [
      Row(
        children: [
          Icon(m.type.icon, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(child: Text(m.name, style: theme.textTheme.titleLarge)),
          if (m.nsfw) const RepositoryBadge('NSFW'),
        ],
      ),
      if (m.description case final d? when d.trim().isNotEmpty) ...[
        const SizedBox(height: 8),
        Text(d),
      ],
      const SizedBox(height: 12),
      _InfoRow('类型', m.type.label),
      _InfoRow('版本', version),
      _InfoRow('引擎', m.engine.label),
      _InfoRow('ID', m.id),
      if (m.author case final a?) _InfoRow('作者', a),
      if (m.lang case final l?) _InfoRow('语言', l),
      _InfoRow('仓库', widget.repository.name),
      _InfoRow('清单', widget.entry.url.toString()),
      const SizedBox(height: 12),
      Text('将访问的主机', style: theme.textTheme.titleSmall),
      const SizedBox(height: 4),
      for (final host in p.hosts)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              Icon(
                newHosts.contains(host) ? Icons.add_circle : Icons.public,
                size: 16,
                color: newHosts.contains(host)
                    ? theme.colorScheme.error
                    : theme.colorScheme.outline,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SelectableText(
                  host,
                  style: newHosts.contains(host)
                      ? TextStyle(
                          color: theme.colorScheme.error,
                          fontWeight: FontWeight.bold,
                        )
                      : null,
                ),
              ),
              if (newHosts.contains(host)) const RepositoryBadge('新增'),
            ],
          ),
        ),
      if (newHosts.isNotEmpty) ...[
        const SizedBox(height: 12),
        RepositoryMessageBox(
          messages: ['新版本会访问 ${newHosts.length} 个之前没有的主机，更新前需要再次确认'],
          error: true,
        ),
      ],
      if (p.warnings.isNotEmpty) ...[
        const SizedBox(height: 12),
        RepositoryMessageBox(messages: p.warnings, error: false),
      ],
    ];
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 56,
            child: Text(
              label,
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          Expanded(child: SelectableText(value)),
        ],
      ),
    );
  }
}

class RepositoryBadge extends StatelessWidget {
  const RepositoryBadge(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 11, color: scheme.onErrorContainer),
      ),
    );
  }
}

class RepositoryMessageBox extends StatelessWidget {
  const RepositoryMessageBox({
    super.key,
    required this.messages,
    required this.error,
  });

  final List<String> messages;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = error ? scheme.errorContainer : scheme.tertiaryContainer;
    final fg = error ? scheme.onErrorContainer : scheme.onTertiaryContainer;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            error ? Icons.error_outline : Icons.info_outline,
            size: 20,
            color: fg,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final m in messages) Text(m, style: TextStyle(color: fg)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
