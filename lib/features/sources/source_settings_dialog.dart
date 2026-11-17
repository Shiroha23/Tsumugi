import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../sources/model/manifest.dart';
import '../../sources/model/source_settings.dart';
import '../../sources/registry/providers.dart';

/// 源菜单「源设置」：按清单 `settings` 渲染（docs/source-spec.md §1.1）。
///
/// 保存后返回 true；取消返回 false / null。保存会让该源的运行实例在下一次请求时按新值重建。
Future<bool?> showSourceSettingsDialog(
  BuildContext context,
  InstalledSource source,
) => showDialog<bool>(
  context: context,
  builder: (_) => SourceSettingsDialog(source: source),
);

class SourceSettingsDialog extends ConsumerStatefulWidget {
  const SourceSettingsDialog({super.key, required this.source});

  final InstalledSource source;

  @override
  ConsumerState<SourceSettingsDialog> createState() =>
      _SourceSettingsDialogState();
}

class _SourceSettingsDialogState extends ConsumerState<SourceSettingsDialog> {
  late final List<SourceSetting> _items;
  late final Map<String, Object?> _values;
  final _controllers = <String, TextEditingController>{};
  bool _saving = false;

  /// 「恢复默认」后递增，让下拉框以新的初始值重建。
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    final m = widget.source.manifest;
    _items = m == null ? const [] : editableSettings(m);
    _values = {...widget.source.settings};
    for (final s in _items) {
      if (s.kind == SourceSettingType.text) {
        _controllers[s.key] = TextEditingController(
          text: _values[s.key] as String? ?? '',
        );
      }
    }
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _resetDefaults() {
    setState(() {
      _generation++;
      for (final s in _items) {
        final d = s.effectiveDefault;
        _values[s.key] = d;
        _controllers[s.key]?.text = d as String? ?? '';
      }
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ref.read(sourceRegistryProvider).setSettings(widget.source.id, {
        for (final s in _items) s.key: _values[s.key],
      });
      if (mounted) Navigator.of(context).pop(true);
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text('保存设置失败：$e')));
    }
  }

  Widget _buildItem(SourceSetting s) => switch (s.kind) {
    SourceSettingType.select => Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: DropdownButtonFormField<String>(
        key: ValueKey(_generation),
        initialValue: _values[s.key] as String?,
        isExpanded: true,
        decoration: InputDecoration(labelText: s.label),
        items: [
          for (final o in s.options)
            DropdownMenuItem(
              value: o,
              child: Text(o, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: _saving ? null : (v) => setState(() => _values[s.key] = v),
      ),
    ),
    SourceSettingType.switchType => SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(s.label),
      value: _values[s.key] == true,
      onChanged: _saving ? null : (v) => setState(() => _values[s.key] = v),
    ),
    SourceSettingType.text => Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: TextField(
        controller: _controllers[s.key],
        enabled: !_saving,
        maxLength: maxSettingTextLength,
        inputFormatters: [FilteringTextInputFormatter.deny(RegExp('[\r\n]'))],
        decoration: InputDecoration(labelText: s.label, counterText: ''),
        onChanged: (v) => _values[s.key] = v,
      ),
    ),
    null => const SizedBox.shrink(),
  };

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('源设置 · ${widget.source.name}'),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final s in _items)
                KeyedSubtree(
                  key: ValueKey('setting-${s.key}'),
                  child: _buildItem(s),
                ),
              const SizedBox(height: 8),
              Text(
                '保存后从下一次请求起生效。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : _resetDefaults,
          child: const Text('恢复默认'),
        ),
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: const Text('保存'),
        ),
      ],
    );
  }
}
