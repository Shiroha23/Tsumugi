import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/sync/providers.dart';
import '../../../sources/registry/providers.dart';
import '../../sources/labels.dart';

/// 预览并确认安装同步来的源（architecture §4.6）：与本地导入一样展示名称、版本与将访问的主机；
/// 更新时新增的主机单独高亮，需要再勾选确认（同 §4.4）。安装成功时返回 true。
Future<bool?> showPendingSourceDialog(
  BuildContext context,
  PendingSource pending,
) => showDialog<bool>(
  context: context,
  barrierDismissible: false,
  builder: (_) => PendingSourceDialog(pending: pending),
);

class PendingSourceDialog extends ConsumerStatefulWidget {
  const PendingSourceDialog({super.key, required this.pending});

  final PendingSource pending;

  @override
  ConsumerState<PendingSourceDialog> createState() =>
      _PendingSourceDialogState();
}

class _PendingSourceDialogState extends ConsumerState<PendingSourceDialog> {
  ImportPreview? _preview;
  List<String>? _errors;
  bool _busy = true;
  bool _hostsConfirmed = false;

  SyncService get _service => ref.read(syncServiceProvider);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final preview = await _service.preparePending(widget.pending);
      if (mounted) setState(() => _preview = preview);
    } on SourceImportException catch (e) {
      if (mounted) setState(() => _errors = e.messages);
    } catch (e) {
      if (mounted) setState(() => _errors = ['$e']);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 新清单相对已安装版本新增的主机。
  List<String> _addedHosts(ImportPreview p) {
    final old = p.existing?.manifest;
    if (old == null) return const [];
    final before = manifestHosts(old).toSet();
    return [
      for (final h in p.hosts)
        if (!before.contains(h)) h,
    ];
  }

  Future<void> _install() async {
    setState(() {
      _busy = true;
      _errors = null;
    });
    try {
      await _service.installPending(widget.pending, _preview!);
      if (mounted) Navigator.of(context).pop(true);
    } on SourceImportException catch (e) {
      if (mounted) setState(() => _errors = e.messages);
    } catch (e) {
      if (mounted) setState(() => _errors = ['$e']);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    final added = preview == null ? const <String>[] : _addedHosts(preview);
    final canInstall =
        preview != null && !_busy && (added.isEmpty || _hostsConfirmed);
    return AlertDialog(
      title: Text(widget.pending.isUpdate ? '更新同步来的源' : '安装同步来的源'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (preview == null && _busy)
                const Center(child: CircularProgressIndicator()),
              if (preview != null) ..._previewBody(preview, added),
              if (_errors case final errors?) ...[
                const SizedBox(height: 12),
                _ErrorBox(errors),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: canInstall ? _install : null,
          child: Text(widget.pending.isUpdate ? '更新' : '安装'),
        ),
      ],
    );
  }

  List<Widget> _previewBody(ImportPreview p, List<String> added) {
    final theme = Theme.of(context);
    final m = p.manifest;
    final version = p.existing == null
        ? m.version
        : '${p.existing!.version} → ${m.version}';
    final origin = widget.pending.originUrl;
    return [
      Text('这个源来自同步文件，不是你在本机导入的。只安装你信任的源。', style: theme.textTheme.bodySmall),
      const SizedBox(height: 12),
      Row(
        children: [
          Icon(m.type.icon, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(child: Text(m.name, style: theme.textTheme.titleLarge)),
        ],
      ),
      const SizedBox(height: 8),
      _Row('类型', m.type.label),
      _Row('版本', version),
      _Row('引擎', m.engine.label),
      _Row('ID', m.id),
      if (origin != null && origin.isNotEmpty)
        _Row('来源', '$origin（同步文件中记录，未验证）'),
      const SizedBox(height: 12),
      Text('将访问的主机', style: theme.textTheme.titleSmall),
      const SizedBox(height: 4),
      for (final host in p.hosts)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              Icon(
                added.contains(host) ? Icons.new_releases : Icons.public,
                size: 16,
                color: added.contains(host)
                    ? theme.colorScheme.error
                    : theme.colorScheme.outline,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SelectableText(
                  added.contains(host) ? '$host（新增）' : host,
                  style: added.contains(host)
                      ? TextStyle(
                          color: theme.colorScheme.error,
                          fontWeight: FontWeight.bold,
                        )
                      : null,
                ),
              ),
            ],
          ),
        ),
      if (added.isNotEmpty)
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: _hostsConfirmed,
          onChanged: _busy
              ? null
              : (v) => setState(() => _hostsConfirmed = v ?? false),
          title: Text('允许访问新增的 ${added.length} 个主机'),
        ),
      for (final w in p.warnings)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(w, style: theme.textTheme.bodySmall),
        ),
    ];
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 56,
          child: Text(
            label,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(child: SelectableText(value)),
      ],
    ),
  );
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox(this.messages);

  final List<String> messages;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final m in messages)
            Text(m, style: TextStyle(color: scheme.onErrorContainer)),
        ],
      ),
    );
  }
}
