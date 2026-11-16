import 'package:flutter/material.dart';

import 'video_playlist.dart';

/// 播放页的选集面板：线路切换（多于一条时）、上一集 / 下一集与当前线路的剧集列表。
class VideoEpisodePanel extends StatelessWidget {
  const VideoEpisodePanel({
    super.key,
    required this.playlist,
    required this.current,
    required this.readUnitIds,
    required this.onOpen,
    required this.onSwitchLine,
  });

  final VideoPlaylist playlist;

  /// 正在播放的剧集；详情中找不到时为 null（只显示第一条线路，不高亮）。
  final EpisodeLocation? current;
  final Set<String> readUnitIds;
  final ValueChanged<EpisodeLocation> onOpen;
  final ValueChanged<int> onSwitchLine;

  @override
  Widget build(BuildContext context) {
    final lines = playlist.lines;
    final line = (current?.line ?? 0).clamp(0, lines.length - 1);
    final units = lines.isEmpty ? const [] : lines[line].units;
    final prev = current == null ? null : playlist.neighbor(current!, -1);
    final next = current == null ? null : playlist.neighbor(current!, 1);
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
          child: Row(
            children: [
              Text('选集（${units.length}）', style: theme.textTheme.titleMedium),
              const Spacer(),
              IconButton(
                tooltip: '上一集',
                icon: const Icon(Icons.skip_previous),
                onPressed: prev == null ? null : () => onOpen(prev),
              ),
              IconButton(
                tooltip: '下一集',
                icon: const Icon(Icons.skip_next),
                onPressed: next == null ? null : () => onOpen(next),
              ),
            ],
          ),
        ),
        if (lines.length > 1)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                for (final (i, g) in lines.indexed)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(g.name),
                      selected: i == line,
                      onSelected: (_) {
                        if (i != line) onSwitchLine(i);
                      },
                    ),
                  ),
              ],
            ),
          ),
        Expanded(
          child: units.isEmpty
              ? const Center(child: Text('没有剧集'))
              : ListView.builder(
                  itemCount: units.length,
                  itemBuilder: (context, i) {
                    final unit = units[i];
                    final playing =
                        current?.line == line && current?.index == i;
                    final read = readUnitIds.contains(unit.id);
                    return ListTile(
                      selected: playing,
                      title: Text(
                        unit.title,
                        style: read && !playing
                            ? TextStyle(color: muted)
                            : null,
                      ),
                      trailing: playing
                          ? const Icon(Icons.play_arrow, semanticLabel: '正在播放')
                          : read
                          ? Icon(Icons.check, color: muted, semanticLabel: '已看')
                          : null,
                      onTap: playing
                          ? null
                          : () => onOpen((line: line, index: i)),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
