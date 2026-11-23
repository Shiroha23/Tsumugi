import '../../sources/model/content.dart';

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
