import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../shared/video/subtitle_providers.dart';
import '../../../sources/model/content.dart';
import 'video_playback.dart';

/// 播放页的字幕选择（architecture §5.2「字幕」、§6.4.7）。
sealed class SubtitleChoice {
  const SubtitleChoice();
}

class SubtitleChoiceOff extends SubtitleChoice {
  const SubtitleChoiceOff();

  @override
  bool operator ==(Object other) => other is SubtitleChoiceOff;

  @override
  int get hashCode => 0;

  @override
  String toString() => 'SubtitleChoiceOff()';
}

/// `content.subtitles[index]`。
class SubtitleChoiceExternal extends SubtitleChoice {
  const SubtitleChoiceExternal(this.index);

  final int index;

  @override
  bool operator ==(Object other) =>
      other is SubtitleChoiceExternal && other.index == index;

  @override
  int get hashCode => index.hashCode;

  @override
  String toString() => 'SubtitleChoiceExternal($index)';
}

/// HLS 流自带的字幕轨：按标签匹配（换清晰度后轨道编号会变）。
class SubtitleChoiceEmbedded extends SubtitleChoice {
  const SubtitleChoiceEmbedded(this.label);

  final String label;

  @override
  bool operator ==(Object other) =>
      other is SubtitleChoiceEmbedded && other.label == label;

  @override
  int get hashCode => label.hashCode;

  @override
  String toString() => 'SubtitleChoiceEmbedded($label)';
}

/// 播放器报告的一条内嵌字幕轨（media_kit `SubtitleTrack` 的子集）。
@immutable
class EmbeddedSubtitle {
  const EmbeddedSubtitle(this.id, {this.title, this.language});

  final String id;
  final String? title;
  final String? language;

  @override
  bool operator ==(Object other) =>
      other is EmbeddedSubtitle &&
      other.id == id &&
      other.title == title &&
      other.language == language;

  @override
  int get hashCode => Object.hash(id, title, language);
}

String? _nonEmpty(String? s) {
  final t = s?.trim();
  return t == null || t.isEmpty ? null : t;
}

/// 外挂字幕的标签：`lang`，缺省为“字幕 n”。
String externalSubtitleLabel(List<SubtitleRef> subtitles, int index) =>
    _nonEmpty(subtitles[index].lang) ?? '字幕 ${index + 1}';

/// 内嵌字幕轨的标签：名称 → 语言 → “内嵌字幕 n”。
String embeddedSubtitleLabel(List<EmbeddedSubtitle> tracks, int index) =>
    _nonEmpty(tracks[index].title) ??
    _nonEmpty(tracks[index].language) ??
    '内嵌字幕 ${index + 1}';

bool _sameLabel(String? a, String b) =>
    a != null && a.trim().toLowerCase() == b.trim().toLowerCase();

/// [tracks] 中与 [label] 相符的轨道下标（标签、名称或语言相同，不区分大小写），没有时为 -1。
int matchEmbeddedSubtitle(List<EmbeddedSubtitle> tracks, String label) {
  for (var i = 0; i < tracks.length; i++) {
    final t = tracks[i];
    if (_sameLabel(embeddedSubtitleLabel(tracks, i), label) ||
        _sameLabel(t.title, label) ||
        _sameLabel(t.language, label)) {
      return i;
    }
  }
  return -1;
}

/// 按记住的选择 [preference] 选字幕：关闭 → 关闭；标签 → 标签相同的外挂字幕 → 相符的内嵌轨；
/// 没有记录或找不到时选第一条可用的外挂字幕（跳过 [failed] 中加载失败的），没有则关闭。
SubtitleChoice pickSubtitle({
  required SubtitlePreference? preference,
  required List<SubtitleRef> external,
  required List<EmbeddedSubtitle> embedded,
  Set<int> failed = const {},
}) {
  switch (preference) {
    case SubtitleOff():
      return const SubtitleChoiceOff();
    case SubtitleLabel(:final label):
      for (var i = 0; i < external.length; i++) {
        if (!failed.contains(i) &&
            _sameLabel(externalSubtitleLabel(external, i), label)) {
          return SubtitleChoiceExternal(i);
        }
      }
      if (matchEmbeddedSubtitle(embedded, label) >= 0) {
        return SubtitleChoiceEmbedded(label);
      }
    case null:
  }
  for (var i = 0; i < external.length; i++) {
    if (!failed.contains(i)) return SubtitleChoiceExternal(i);
  }
  return const SubtitleChoiceOff();
}

/// 用户选择 [choice] 时应记住的偏好。
SubtitlePreference subtitlePreferenceFor(
  SubtitleChoice choice,
  List<SubtitleRef> external,
) => switch (choice) {
  SubtitleChoiceOff() => const SubtitleOff(),
  SubtitleChoiceExternal(:final index) => SubtitleLabel(
    externalSubtitleLabel(external, index),
  ),
  SubtitleChoiceEmbedded(:final label) => SubtitleLabel(label),
};

/// 当前应显示的字幕文字：外挂字幕按播放位置取，内嵌轨取播放器报告的文字（media_kit 的 `sub-text`）。
class VideoSubtitleController extends ValueNotifier<String> {
  VideoSubtitleController({
    required this.playback,
    required Stream<List<String>> embeddedText,
  }) : super('') {
    playback.addListener(_update);
    _subscription = embeddedText.listen((t) {
      _embedded = t.isEmpty ? '' : t.first;
      _update();
    });
  }

  final ValueListenable<VideoPlaybackState> playback;
  late final StreamSubscription<List<String>> _subscription;
  SubtitleDocument? _document;
  bool _showEmbedded = false;
  String _embedded = '';

  /// 显示外挂字幕 [document]。
  void showDocument(SubtitleDocument document) {
    _document = document;
    _showEmbedded = false;
    _update();
  }

  /// 显示内嵌轨的文字。
  void showEmbedded() {
    _document = null;
    _showEmbedded = true;
    _update();
  }

  /// 不显示（关闭，或外挂字幕加载中）。
  void hide() {
    _document = null;
    _showEmbedded = false;
    _update();
  }

  void _update() {
    value = _showEmbedded
        ? _embedded.trim()
        : _document?.textAt(playback.value.position) ?? '';
  }

  @override
  void dispose() {
    playback.removeListener(_update);
    _subscription.cancel().ignore();
    super.dispose();
  }
}

/// 画面底部居中的字幕（白字黑边），不拦截手势。字号随画面高度变化。
class VideoSubtitleOverlay extends StatelessWidget {
  const VideoSubtitleOverlay({super.key, required this.text});

  final ValueListenable<String> text;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : MediaQuery.sizeOf(context).height;
        final size = (height * 0.055).clamp(14.0, 36.0);
        return ValueListenableBuilder<String>(
          valueListenable: text,
          builder: (context, value, _) {
            if (value.isEmpty) return const SizedBox.shrink();
            final style = TextStyle(
              fontSize: size,
              height: 1.25,
              fontWeight: FontWeight.w500,
            );
            return Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                // 留出控件底栏的高度。
                padding: EdgeInsets.fromLTRB(24, 0, 24, height * 0.06 + 40),
                child: Stack(
                  children: [
                    Text(
                      value,
                      textAlign: TextAlign.center,
                      style: style.copyWith(
                        foreground: Paint()
                          ..style = PaintingStyle.stroke
                          ..strokeWidth = size / 7
                          ..strokeJoin = StrokeJoin.round
                          ..color = Colors.black,
                      ),
                    ),
                    Text(
                      value,
                      key: const ValueKey('video-subtitle-text'),
                      textAlign: TextAlign.center,
                      style: style.copyWith(color: Colors.white),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    ),
  );
}
