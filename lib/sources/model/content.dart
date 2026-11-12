import 'package:freezed_annotation/freezed_annotation.dart';

import 'common.dart';

part 'content.freezed.dart';
part 'content.g.dart';

/// `content()` 的返回值。具体子类型由源的 [MediaType] 决定（docs/source-spec.md §2.2）。
sealed class MediaContent {
  const MediaContent();

  static MediaContent fromJson(MediaType type, Map<String, dynamic> json) =>
      switch (type) {
        MediaType.comic => ComicContent.fromJson(json),
        MediaType.novel => NovelContent.fromJson(json),
        MediaType.video => VideoContent.fromJson(json),
        MediaType.music => MusicContent.fromJson(json),
      };
}

@freezed
abstract class ImageRef with _$ImageRef {
  const factory ImageRef({required String url, Headers? headers}) = _ImageRef;

  factory ImageRef.fromJson(Map<String, dynamic> json) =>
      _$ImageRefFromJson(json);
}

enum StreamType { hls, dash, mp4, auto }

@freezed
abstract class StreamRef with _$StreamRef {
  const factory StreamRef({
    required String url,
    @JsonKey(unknownEnumValue: StreamType.auto)
    @Default(StreamType.auto)
    StreamType type,
    String? quality,
    Headers? headers,
  }) = _StreamRef;

  factory StreamRef.fromJson(Map<String, dynamic> json) =>
      _$StreamRefFromJson(json);
}

@freezed
abstract class SubtitleRef with _$SubtitleRef {
  const factory SubtitleRef({
    required String url,
    String? lang,
    String? format,
  }) = _SubtitleRef;

  factory SubtitleRef.fromJson(Map<String, dynamic> json) =>
      _$SubtitleRefFromJson(json);
}

enum LyricsFormat { lrc, text }

@freezed
abstract class Lyrics with _$Lyrics {
  const factory Lyrics({
    required LyricsFormat format,
    required String content,
  }) = _Lyrics;

  factory Lyrics.fromJson(Map<String, dynamic> json) => _$LyricsFromJson(json);
}

@freezed
abstract class ComicContent extends MediaContent with _$ComicContent {
  const ComicContent._();
  const factory ComicContent({@Default([]) List<ImageRef> images}) =
      _ComicContent;

  factory ComicContent.fromJson(Map<String, dynamic> json) =>
      _$ComicContentFromJson(json);
}

@freezed
abstract class NovelContent extends MediaContent with _$NovelContent {
  const NovelContent._();
  const factory NovelContent({
    required String text,
    @Default(false) bool html,
    String? nextPageId,
  }) = _NovelContent;

  factory NovelContent.fromJson(Map<String, dynamic> json) =>
      _$NovelContentFromJson(json);
}

@freezed
abstract class VideoContent extends MediaContent with _$VideoContent {
  const VideoContent._();
  const factory VideoContent({
    @Default([]) List<StreamRef> streams,
    @Default([]) List<SubtitleRef> subtitles,
  }) = _VideoContent;

  factory VideoContent.fromJson(Map<String, dynamic> json) =>
      _$VideoContentFromJson(json);
}

@freezed
abstract class MusicContent extends MediaContent with _$MusicContent {
  const MusicContent._();
  const factory MusicContent({
    @Default([]) List<StreamRef> streams,
    Lyrics? lyrics,
  }) = _MusicContent;

  factory MusicContent.fromJson(Map<String, dynamic> json) =>
      _$MusicContentFromJson(json);
}
