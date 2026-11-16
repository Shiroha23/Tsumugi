import '../../../shared/export/export_models.dart' show unitGroupsOf;
import '../../../sources/model/common.dart';
import '../../../sources/model/content.dart';

/// 播放页的剧集位置：第 [line] 条线路（[VideoPlaylist.lines] 的下标）中的第 [index] 集。
typedef EpisodeLocation = ({int line, int index});

/// 详情中的线路与剧集（architecture §5.2「视频播放」）。
///
/// 线路即 [unitGroupsOf]：`groups` 非空时为各线路，否则 `units` 为唯一一条。
final class VideoPlaylist {
  VideoPlaylist(Detail detail) : lines = _linesOf(detail);

  final List<UnitGroup> lines;

  static List<UnitGroup> _linesOf(Detail detail) {
    final groups = unitGroupsOf(detail);
    // `groups` 与 `units` 同时给出、而 `units` 中的剧集不在任何线路里时，把 `units` 也当作一条线路，
    // 这样从 `units` 打开的剧集同样能找到上一集 / 下一集。
    final listed = {
      for (final g in groups)
        for (final u in g.units) u.id,
    };
    if (detail.units.any((u) => !listed.contains(u.id))) {
      return [...groups, UnitGroup(name: '默认', units: detail.units)];
    }
    return groups;
  }

  /// [unitId] 所在的位置；优先 [preferLine]（多条线路含同一 id 时），都不包含时返回 null。
  EpisodeLocation? locate(String unitId, {int? preferLine}) {
    if (preferLine != null && preferLine >= 0 && preferLine < lines.length) {
      final i = lines[preferLine].units.indexWhere((u) => u.id == unitId);
      if (i >= 0) return (line: preferLine, index: i);
    }
    for (final (l, g) in lines.indexed) {
      final i = g.units.indexWhere((u) => u.id == unitId);
      if (i >= 0) return (line: l, index: i);
    }
    return null;
  }

  Unit? unitAt(EpisodeLocation at) {
    if (at.line < 0 || at.line >= lines.length) return null;
    final units = lines[at.line].units;
    return at.index >= 0 && at.index < units.length ? units[at.index] : null;
  }

  /// 同一线路中相邻的剧集（[delta] 为 -1 / 1）；越界返回 null。
  EpisodeLocation? neighbor(EpisodeLocation at, int delta) {
    final next = (line: at.line, index: at.index + delta);
    return unitAt(next) == null ? null : next;
  }

  /// 切换到第 [line] 条线路时对应的剧集：标题相同的剧集，没有则同一下标，再没有则第一集；
  /// 该线路没有剧集时返回 null。
  EpisodeLocation? switchLine(EpisodeLocation at, int line) {
    if (line < 0 || line >= lines.length) return null;
    final units = lines[line].units;
    if (units.isEmpty) return null;
    final title = unitAt(at)?.title;
    final byTitle = title == null
        ? -1
        : units.indexWhere((u) => u.title == title);
    if (byTitle >= 0) return (line: line, index: byTitle);
    if (at.index >= 0 && at.index < units.length) {
      return (line: line, index: at.index);
    }
    return (line: line, index: 0);
  }
}

/// 可以播放的流（清晰度）：跳过 DASH（暂不支持，architecture §6.4.3）。
List<StreamRef> playableStreams(VideoContent content) => [
  for (final s in content.streams)
    if (s.type != StreamType.dash) s,
];

/// 清晰度的显示名：`quality`，缺省为“流 n”（从 1 开始）。
String streamLabel(List<StreamRef> streams, int index) {
  final q = streams[index].quality?.trim();
  return q == null || q.isEmpty ? '流 ${index + 1}' : q;
}

/// 换集后选用的流：与 [preferredLabel] 同名的，否则第一个。[streams] 为空时返回 -1。
int pickStream(List<StreamRef> streams, String? preferredLabel) {
  if (streams.isEmpty) return -1;
  if (preferredLabel != null) {
    for (var i = 0; i < streams.length; i++) {
      if (streamLabel(streams, i) == preferredLabel) return i;
    }
  }
  return 0;
}

/// 是否视为已看完：播放完成，或位置到达时长的 97%（片尾）。
bool isFinished(
  Duration position,
  Duration duration, {
  required bool completed,
}) =>
    completed ||
    (duration > Duration.zero &&
        position.inMilliseconds >= duration.inMilliseconds * 0.97);

/// 进度的显示形式：`m:ss`，一小时以上为 `h:mm:ss`。
String formatPlaybackPosition(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60);
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
}
