import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../sources/registry/providers.dart';
import 'labels.dart';
import 'manifest_file_picker.dart';

/// 导入源：粘贴 JSON / 剪贴板 / 选择文件 → 预览（名称、类型、版本、访问的主机）→ 安装。
///
/// 安装成功时以 [InstalledSource] 关闭，取消时返回 null。
Future<InstalledSource?> showImportSourceDialog(BuildContext context) =>
    showDialog<InstalledSource>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const ImportSourceDialog(),
    );

class ImportSourceDialog extends ConsumerStatefulWidget {
  const ImportSourceDialog({super.key});

  @override
  ConsumerState<ImportSourceDialog> createState() => _ImportSourceDialogState();
}

class _ImportSourceDialogState extends ConsumerState<ImportSourceDialog> {
  final _text = TextEditingController();
  List<String>? _errors;
  ImportPreview? _preview;
  bool _busy = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  SourceRegistry get _registry => ref.read(sourceRegistryProvider);

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _errors = null;
    });
    try {
      await action();
    } on SourceImportException catch (e) {
      if (mounted) setState(() => _errors = e.messages);
    } catch (e) {
      if (mounted) setState(() => _errors = ['$e']);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _parseText() => _run(() async {
    final text = _text.text.trim();
    if (text.isEmpty) {
      setState(() => _errors = ['请先粘贴源清单 JSON']);
      return;
    }
    final preview = await _registry.prepareImport(text);
    if (mounted) setState(() => _preview = preview);
  });

  void _pasteClipboard() => _run(() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      setState(() => _errors = ['剪贴板中没有文本']);
      return;
    }
    _text.text = text;
    final preview = await _registry.prepareImport(text);
    if (mounted) setState(() => _preview = preview);
  });

  void _pickFile() => _run(() async {
    final file = await ref.read(manifestFilePickerProvider).pick();
    if (file == null) return;
    final preview = await _registry.prepareImportBytes(
      file.bytes,
      origin: SourceOrigin.local(file.name),
    );
    if (mounted) setState(() => _preview = preview);
  });

  void _install() => _run(() async {
    final installed = await _registry.install(_preview!);
    if (mounted) Navigator.of(context).pop(installed);
  });

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    return AlertDialog(
      title: Text(preview == null ? '导入源' : _previewTitle(preview)),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (preview == null)
                ..._inputStep()
              else
                ..._previewStep(preview),
              if (_errors case final errors?) ...[
                const SizedBox(height: 12),
                _MessageBox(messages: errors, error: true),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (preview == null) ...[
          TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: _busy ? null : _parseText,
            child: const Text('下一步'),
          ),
        ] else ...[
          TextButton(
            onPressed: _busy
                ? null
                : () => setState(() {
                    _preview = null;
                    _errors = null;
                  }),
            child: const Text('返回'),
          ),
          FilledButton(
            onPressed: _busy ? null : _install,
            child: Text(switch (preview.action) {
              ImportAction.install => '安装',
              ImportAction.upgrade => '更新',
              ImportAction.reinstall => '覆盖',
            }),
          ),
        ],
      ],
    );
  }

  String _previewTitle(ImportPreview p) => switch (p.action) {
    ImportAction.install => '安装源',
    ImportAction.upgrade => '更新源',
    ImportAction.reinstall => '覆盖源',
  };

  List<Widget> _inputStep() => [
    TextField(
      controller: _text,
      enabled: !_busy,
      minLines: 8,
      maxLines: 14,
      style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
      decoration: const InputDecoration(
        hintText: '在此粘贴源清单 JSON',
        border: OutlineInputBorder(),
      ),
    ),
    const SizedBox(height: 8),
    Wrap(
      spacing: 8,
      children: [
        TextButton.icon(
          onPressed: _busy ? null : _pasteClipboard,
          icon: const Icon(Icons.content_paste),
          label: const Text('从剪贴板粘贴'),
        ),
        TextButton.icon(
          onPressed: _busy ? null : _pickFile,
          icon: const Icon(Icons.file_open_outlined),
          label: const Text('选择文件'),
        ),
      ],
    ),
    const SizedBox(height: 4),
    Text(
      '只导入你信任的源。源会以你的设备访问它声明的网站。',
      style: Theme.of(context).textTheme.bodySmall,
    ),
  ];

  List<Widget> _previewStep(ImportPreview p) {
    final m = p.manifest;
    final theme = Theme.of(context);
    final version = p.existing == null
        ? m.version
        : '${p.existing!.version} → ${m.version}';
    return [
      Row(
        children: [
          Icon(m.type.icon, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(child: Text(m.name, style: theme.textTheme.titleLarge)),
          if (m.nsfw) const _Badge('NSFW'),
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
      const SizedBox(height: 12),
      Text('将访问的主机', style: theme.textTheme.titleSmall),
      const SizedBox(height: 4),
      for (final host in p.hosts)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              Icon(Icons.public, size: 16, color: theme.colorScheme.outline),
              const SizedBox(width: 8),
              Expanded(child: SelectableText(host)),
            ],
          ),
        ),
      if (p.warnings.isNotEmpty) ...[
        const SizedBox(height: 12),
        _MessageBox(messages: p.warnings, error: false),
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

class _Badge extends StatelessWidget {
  const _Badge(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
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

class _MessageBox extends StatelessWidget {
  const _MessageBox({required this.messages, required this.error});

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
