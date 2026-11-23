import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/download/providers.dart';
import '../../shared/export/export_models.dart' show ExportRange, unitGroupsOf;
import '../../shared/library/library_item.dart';
import '../../shared/video/video_streams.dart';
import '../../sources/model/common.dart';
import '../../sources/model/content.dart';
import '../../sources/runtime/source_runtime.dart';

/// 详情页「下载」：选择线路与章节范围（同导出），加入下载队列（architecture §4.5）。
/// 视频另选一个清晰度（architecture §4.5.1：`content.streams` 中非 DASH 的流，取自所选线路的第一集；
/// 下载每集时选同名的流，没有则第一个）。
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

  bool get _video => widget.item.mediaType == MediaType.video;
  String get _unitWord => _video ? '集' : '章';

  /// 视频：所选线路第一集的清晰度（null：正在获取；空：取不到，下载时用第一个）。
  List<String>? _qualities;
  String? _quality;
  int _qualityGeneration = 0;

  @override
  void initState() {
    super.initState();
    _end = (_units.length - 1).clamp(0, 1 << 30);
    if (_video) _loadQualities();
  }

  void _selectGroup(int group) {
    setState(() {
      _group = group;
      _start = 0;
      _end = (_units.length - 1).clamp(0, 1 << 30);
    });
    if (_video) _loadQualities();
  }

  Future<void> _loadQualities() async {
    final generation = ++_qualityGeneration;
    setState(() {
      _qualities = null;
      _quality = null;
    });
    var labels = const <String>[];
    try {
      final first = _units.firstOrNull;
      if (first != null) {
        final source = await ref.read(
          sourceInstanceProvider(widget.item.sourceId).future,
        );
        final content = await source.content(first.id);
        if (content is VideoContent) {
          final streams = playableStreams(content);
          labels = [
            for (var i = 0; i < streams.length; i++) streamLabel(streams, i),
          ];
        }
      }
    } on Object {
      labels = const [];
    }
    if (!mounted || generation != _qualityGeneration) return;
    setState(() {
      _qualities = labels;
      _quality = labels.firstOrNull;
    });
  }

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
            streamLabel: _video ? _quality : null,
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
                        child: Text('${g.name}（${g.units.length} $_unitWord）'),
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
                      title: Text(
                        _video
                            ? '全部剧集（${units.length} 集）'
                            : '全部章节（${units.length} 章）',
                      ),
                    ),
                    RadioListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _RangeMode.span,
                      title: Text(_video ? '起止剧集' : '起止章节'),
                    ),
                  ],
                ),
              ),
              if (_mode == _RangeMode.span && units.isNotEmpty) ...[
                _unitPicker('从', _start, (v) => setState(() => _start = v)),
                _unitPicker('到', _end, (v) => setState(() => _end = v)),
              ],
              if (_video) ..._qualityPicker(theme),
              const SizedBox(height: 8),
              Text(
                _video
                    ? '将下载 $count 集（已下载的剧集跳过），用于应用内离线播放。'
                          '直播与不支持的加密方式不能下载。下载遵守该源的限速；Android 上切到后台后继续，iOS 上只能在后台继续约 30 秒。'
                    : '将下载 $count 章（已下载的章节跳过），用于应用内离线阅读。'
                          '下载遵守该源的限速；Android 上切到后台后继续，iOS 上只能在后台继续约 30 秒。',
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
          onPressed: units.isEmpty || _busy || (_video && _qualities == null)
              ? null
              : _download,
          child: const Text('开始下载'),
        ),
      ],
    );
  }

  List<Widget> _qualityPicker(ThemeData theme) {
    final qualities = _qualities;
    return [
      const SizedBox(height: 8),
      Text('清晰度', style: theme.textTheme.labelLarge),
      if (qualities == null)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: LinearProgressIndicator(),
        )
      else if (qualities.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            '取不到清晰度列表，将下载每集的第一个清晰度',
            style: theme.textTheme.bodySmall,
          ),
        )
      else
        DropdownButton<String>(
          key: const ValueKey('download-quality'),
          isExpanded: true,
          value: _quality,
          items: [
            for (final q in {...qualities})
              DropdownMenuItem(value: q, child: Text(q)),
          ],
          onChanged: (v) => setState(() => _quality = v ?? _quality),
        ),
    ];
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
