import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/download/providers.dart';
import '../../shared/export/export_models.dart' show ExportRange, unitGroupsOf;
import '../../shared/library/library_item.dart';
import '../../sources/model/common.dart';

/// 详情页「下载」：选择线路与章节范围（同导出），加入下载队列（architecture §4.5）。
///
/// 返回加入队列的章节数；取消时返回 null。
Future<int?> showDownloadDialog(
  BuildContext context, {
  required LibraryItem item,
  required Detail detail,
}) => showDialog<int>(
  context: context,
  builder: (_) => DownloadDialog(item: item, detail: detail),
);

class DownloadDialog extends ConsumerStatefulWidget {
  const DownloadDialog({super.key, required this.item, required this.detail});

  final LibraryItem item;
  final Detail detail;

  @override
  ConsumerState<DownloadDialog> createState() => _DownloadDialogState();
}

enum _RangeMode { all, span }

class _DownloadDialogState extends ConsumerState<DownloadDialog> {
  int _group = 0;
  _RangeMode _mode = _RangeMode.all;
  int _start = 0;
  int _end = 0;
  bool _busy = false;

  late final List<UnitGroup> _groups = unitGroupsOf(widget.detail);

  List<Unit> get _units => _groups[_group].units;

  @override
  void initState() {
    super.initState();
    _end = (_units.length - 1).clamp(0, 1 << 30);
  }

  void _selectGroup(int group) => setState(() {
    _group = group;
    _start = 0;
    _end = (_units.length - 1).clamp(0, 1 << 30);
  });

  Future<void> _download() async {
    final range = ExportRange(
      group: _group,
      start: _mode == _RangeMode.span ? _start : null,
      end: _mode == _RangeMode.span ? _end : null,
    );
    final selected = range.select(widget.detail);
    final group = _groups[_group];
    final indexOf = {for (final (i, u) in group.units.indexed) u.id: i};
    setState(() => _busy = true);
    final n = await ref.read(downloadManagerProvider).enqueue(
      widget.item,
      widget.detail,
      [
        for (final u in selected)
          DownloadRequestUnit(
            u,
            groupName: group.name,
            index: indexOf[u.id] ?? 0,
          ),
      ],
    );
    if (mounted) Navigator.of(context).pop(n);
  }

  @override
  Widget build(BuildContext context) {
    final units = _units;
    final theme = Theme.of(context);
    final count = _mode == _RangeMode.all
        ? units.length
        : (_end - _start).abs() + 1;
    return AlertDialog(
      title: const Text('下载'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_groups.length > 1) ...[
                Text('线路', style: theme.textTheme.labelLarge),
                DropdownButton<int>(
                  isExpanded: true,
                  value: _group,
                  items: [
                    for (final (i, g) in _groups.indexed)
                      DropdownMenuItem(
                        value: i,
                        child: Text('${g.name}（${g.units.length} 章）'),
                      ),
                  ],
                  onChanged: (v) => v == null ? null : _selectGroup(v),
                ),
                const SizedBox(height: 8),
              ],
              Text('范围', style: theme.textTheme.labelLarge),
              RadioGroup<_RangeMode>(
                groupValue: _mode,
                onChanged: (v) => setState(() => _mode = v ?? _mode),
                child: Column(
                  children: [
                    RadioListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _RangeMode.all,
                      title: Text('全部章节（${units.length} 章）'),
                    ),
                    RadioListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _RangeMode.span,
                      title: const Text('起止章节'),
                    ),
                  ],
                ),
              ),
              if (_mode == _RangeMode.span && units.isNotEmpty) ...[
                _unitPicker('从', _start, (v) => setState(() => _start = v)),
                _unitPicker('到', _end, (v) => setState(() => _end = v)),
              ],
              const SizedBox(height: 8),
              Text(
                '将下载 $count 章（已下载的章节跳过），用于应用内离线阅读。'
                '下载遵守该源的限速，在应用打开期间进行。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: units.isEmpty || _busy ? null : _download,
          child: const Text('开始下载'),
        ),
      ],
    );
  }

  Widget _unitPicker(String label, int value, ValueChanged<int> onChanged) =>
      Row(
        children: [
          SizedBox(width: 32, child: Text(label)),
          Expanded(
            child: DropdownButton<int>(
              key: ValueKey('download-range-$label'),
              isExpanded: true,
              value: value.clamp(0, _units.length - 1),
              items: [
                for (final (i, u) in _units.indexed)
                  DropdownMenuItem(
                    value: i,
                    child: Text(
                      '${i + 1}. ${u.title}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (v) => v == null ? null : onChanged(v),
            ),
          ),
        ],
      );
}
