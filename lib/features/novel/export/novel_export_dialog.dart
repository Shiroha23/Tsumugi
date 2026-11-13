import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/export/providers.dart';
import '../../../shared/widgets/source_error_view.dart';
import '../../../sources/model/common.dart';
import '../../../sources/runtime/source_error_text.dart';

/// 打开小说导出对话框：选择格式与范围 → 逐章导出（进度、暂停 / 重试 / 跳过 / 取消）→ 保存。
Future<void> showNovelExportDialog(
  BuildContext context, {
  required String sourceId,
  required String itemId,
  required Detail detail,
  Headers? coverHeaders,
}) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => NovelExportDialog(
    sourceId: sourceId,
    itemId: itemId,
    detail: detail,
    coverHeaders: coverHeaders,
  ),
);

class NovelExportDialog extends ConsumerStatefulWidget {
  const NovelExportDialog({
    super.key,
    required this.sourceId,
    required this.itemId,
    required this.detail,
    this.coverHeaders,
  });

  final String sourceId;
  final String itemId;
  final Detail detail;
  final Headers? coverHeaders;

  @override
  ConsumerState<NovelExportDialog> createState() => _NovelExportDialogState();
}

enum _RangeMode { all, span }

class _NovelExportDialogState extends ConsumerState<NovelExportDialog> {
  ExportFormat _format = ExportFormat.epub;
  int _group = 0;
  _RangeMode _mode = _RangeMode.all;
  int _start = 0;
  int _end = 0;
  bool _bom = false;

  NovelExportJob? _job;
  bool _saving = false;
  String? _savedTo;
  Object? _saveError;

  late final List<UnitGroup> _groups = unitGroupsOf(widget.detail);

  List<Unit> get _units => _groups[_group].units;

  @override
  void initState() {
    super.initState();
    _end = (_units.length - 1).clamp(0, 1 << 30);
  }

  @override
  void dispose() {
    _job?.dispose();
    super.dispose();
  }

  void _selectGroup(int group) => setState(() {
    _group = group;
    _start = 0;
    _end = (_units.length - 1).clamp(0, 1 << 30);
  });

  void _beginExport() {
    final range = ExportRange(
      group: _group,
      start: _mode == _RangeMode.span ? _start : null,
      end: _mode == _RangeMode.span ? _end : null,
    );
    final job = ref
        .read(novelExporterProvider)
        .create(
          NovelExportRequest(
            sourceId: widget.sourceId,
            itemId: widget.itemId,
            detail: widget.detail,
            units: range.select(widget.detail),
            format: _format,
            coverHeaders: widget.coverHeaders,
            txtBom: _bom,
          ),
        );
    job.addListener(_onJob);
    setState(() => _job = job);
    // 失败已反映在 status 中。
    job.run().ignore();
  }

  void _onJob() {
    if (mounted) setState(() {});
  }

  Future<void> _save(ExportFile file) async {
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      final where = await ref.read(exportSaverProvider).save(file);
      if (mounted && where != null) setState(() => _savedTo = where);
    } on Object catch (e) {
      if (mounted) setState(() => _saveError = e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _close() {
    _job?.cancel();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final job = _job;
    return job == null ? _buildOptions(context) : _buildProgress(context, job);
  }

  // ---------------------------------------------------------------------------
  // 选项

  Widget _buildOptions(BuildContext context) {
    final units = _units;
    final theme = Theme.of(context);
    final count = _mode == _RangeMode.all
        ? units.length
        : (_end - _start).abs() + 1;
    return AlertDialog(
      title: const Text('导出小说'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('格式', style: theme.textTheme.labelLarge),
              const SizedBox(height: 8),
              SegmentedButton<ExportFormat>(
                segments: [
                  for (final f in ExportFormat.values)
                    ButtonSegment(value: f, label: Text(f.label)),
                ],
                selected: {_format},
                onSelectionChanged: (s) => setState(() => _format = s.first),
              ),
              if (_format == ExportFormat.txt)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _bom,
                  onChanged: (v) => setState(() => _bom = v ?? false),
                  title: const Text('添加 UTF-8 BOM'),
                  subtitle: const Text('兼容旧版 Windows 记事本'),
                ),
              const SizedBox(height: 16),
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
                '将导出 $count 章。章节按顺序逐一请求，遵守该源的限速，章节较多时需要一些时间。',
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
          onPressed: units.isEmpty ? null : _beginExport,
          child: const Text('开始导出'),
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
              key: ValueKey('export-range-$label'),
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

  // ---------------------------------------------------------------------------
  // 进度与结果

  Widget _buildProgress(BuildContext context, NovelExportJob job) {
    final s = job.status;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final children = <Widget>[];
    final actions = <Widget>[];

    switch (s.phase) {
      case ExportPhase.fetching || ExportPhase.building:
        children.addAll([
          LinearProgressIndicator(
            value: s.phase == ExportPhase.building ? null : s.fraction,
          ),
          const SizedBox(height: 12),
          Text(
            s.phase == ExportPhase.building
                ? '正在生成 ${_format.label} 文件…'
                : '正在导出 ${s.completed + 1} / ${s.total}：${s.current?.title ?? ''}',
          ),
        ]);
        actions.add(TextButton(onPressed: _close, child: const Text('取消导出')));
      case ExportPhase.paused:
        children.addAll([
          LinearProgressIndicator(value: s.fraction),
          const SizedBox(height: 12),
          Text(
            '「${s.current?.title ?? ''}」导出失败（${s.completed + 1} / ${s.total}）',
          ),
          SourceErrorView(
            error: s.error!,
            sourceId: widget.sourceId,
            onRetry: job.retry,
          ),
        ]);
        final verify = describeSourceError(s.error!).needsVerification;
        actions.addAll([
          TextButton(onPressed: _close, child: const Text('取消导出')),
          TextButton(onPressed: job.skip, child: const Text('跳过本章')),
          if (!verify)
            TextButton(
              onPressed: () => job.skip(all: true),
              child: const Text('跳过所有失败章节'),
            ),
        ]);
      case ExportPhase.done:
        final file = s.file!;
        children.addAll([
          Text(
            '已导出 ${s.total - s.failures.length} / ${s.total} 章'
            '（${_formatSize(file.bytes.length)}）',
          ),
          const SizedBox(height: 4),
          Text(file.fileName, style: muted),
          if (_savedTo case final where?) ...[
            const SizedBox(height: 8),
            Text('已保存到：$where'),
          ],
          if (_saveError case final e?) ...[
            const SizedBox(height: 8),
            Text('保存失败：$e', style: TextStyle(color: theme.colorScheme.error)),
          ],
        ]);
        actions.addAll([
          TextButton(onPressed: _close, child: const Text('关闭')),
          FilledButton.icon(
            icon: const Icon(Icons.save_alt),
            label: Text(_savedTo == null ? '保存文件' : '另存为'),
            onPressed: _saving ? null : () => _save(file),
          ),
        ]);
      case ExportPhase.failed:
        children.add(
          Text(
            s.error is NothingToExportException
                ? '没有成功导出的章节'
                : '生成文件失败：${s.error}',
            style: TextStyle(color: theme.colorScheme.error),
          ),
        );
        actions.add(TextButton(onPressed: _close, child: const Text('关闭')));
      case ExportPhase.cancelled:
        children.add(const Text('已取消导出'));
        actions.add(TextButton(onPressed: _close, child: const Text('关闭')));
    }

    if (s.failures.isNotEmpty) {
      children.addAll([
        const SizedBox(height: 12),
        Text('已跳过 ${s.failures.length} 章：', style: theme.textTheme.labelLarge),
        for (final f in s.failures)
          Text(
            '· ${f.unit.title}：${describeSourceError(f.error).title}',
            style: muted,
          ),
      ]);
    }

    return AlertDialog(
      title: const Text('导出小说'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: children,
          ),
        ),
      ),
      actions: actions,
    );
  }

  static String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}
