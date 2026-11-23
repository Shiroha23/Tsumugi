import 'dart:convert';

/// 已下载剧集目录中的 `video.json`（architecture §4.5.1「怎么存」）：本地播放列表结构、字幕与续传用的来源标识。
///
/// 目录布局（路径只由序号构成，不含任何外部字符串）：
/// - HLS：`v/NNNNN.<ext>`（视频变体的分片与初始化分片）、`a/…`（音频轨）、`s<k>/NNNNN.vtt`（第 k 条字幕轨）；
/// - 单文件：`media.bin`；
/// - 外挂字幕：`sub-NN.<ext>`。
///
/// 读取时严格校验：任何字段类型不符、文件名不是本客户端为该位置生成的形式，都视为损坏（[FormatException]）。
/// 不保存密钥、播放列表原文与上游地址（上游地址只以哈希出现在 [sourceKey] 中）。

/// HLS 中一个轨道的用途。
enum VideoTrackType { video, audio, subtitles }

/// 分片文件可用的扩展名（按内容识别，与代理“按内容命名”的规则一致，见 `MediaContainer.extension`）。
const videoSegmentExtensions = {
  'ts', 'mp4', 'aac', 'mp3', 'ac3', 'eac3', 'mkv', 'ogg', //
  'flac', 'avi', 'wav', 'flv', 'vtt',
};

/// 外挂字幕文件可用的扩展名（按内容识别的格式）。
const videoSubtitleExtensions = {'srt', 'vtt', 'ass'};

/// 单文件下载的文件名。
const videoFileName = 'media.bin';

/// 剧集目录中的 `video.json`。
const videoManifestFileName = 'video.json';

/// 每个剧集最多的外挂字幕数（文件名两位序号）。
const maxVideoSubtitles = 99;

/// 每个剧集最多的 HLS 字幕轨数（目录 `s1` … `s99`）。
const maxVideoSubtitleTracks = 99;

/// 第 [index]（从 0 开始）项在 [dir] 中的文件名：`v/00001.ts`。
String videoItemFileName(String dir, int index, String extension) {
  if (index < 0 || index >= 99999) throw RangeError.value(index, 'index');
  return '$dir/${(index + 1).toString().padLeft(5, '0')}.$extension';
}

/// 第 [index]（从 0 开始）条外挂字幕的文件名：`sub-01.srt`。
String videoSubtitleFileName(int index, String extension) {
  if (index < 0 || index >= maxVideoSubtitles) {
    throw RangeError.value(index, 'index');
  }
  return 'sub-${(index + 1).toString().padLeft(2, '0')}.$extension';
}

/// 轨道目录名：视频 `v`、音频 `a`、第 k 条字幕轨 `s<k>`（k 从 1 开始）。
String videoTrackDir(VideoTrackType type, [int subtitleIndex = 0]) =>
    switch (type) {
      VideoTrackType.video => 'v',
      VideoTrackType.audio => 'a',
      VideoTrackType.subtitles => 's${subtitleIndex + 1}',
    };

/// 轨道中的一项（初始化分片或分片）。
final class VideoItem {
  const VideoItem({
    required this.init,
    this.duration = 0,
    this.discontinuity = false,
    this.file,
  });

  /// `EXT-X-MAP` 初始化分片。
  final bool init;

  /// `EXTINF` 时长（秒）。
  final double duration;
  final bool discontinuity;

  /// 写完后的文件名（相对剧集目录，[videoItemFileName]）；尚未下载时为 null。
  final String? file;

  VideoItem withFile(String? file) => VideoItem(
    init: init,
    duration: duration,
    discontinuity: discontinuity,
    file: file,
  );
}

/// HLS 中的一个轨道（视频变体、音频轨或一条字幕轨）。
final class VideoTrack {
  const VideoTrack({
    required this.type,
    required this.dir,
    required this.mediaSequence,
    required this.items,
    this.name,
    this.language,
  });

  final VideoTrackType type;

  /// 目录名（[videoTrackDir]）。
  final String dir;
  final int mediaSequence;
  final List<VideoItem> items;

  /// 字幕轨的名称 / 语言（显示用，来自源的播放列表）。
  final String? name;
  final String? language;

  VideoTrack withItems(List<VideoItem> items) => VideoTrack(
    type: type,
    dir: dir,
    mediaSequence: mediaSequence,
    items: items,
    name: name,
    language: language,
  );
}

/// 单文件下载的状态（续传用）。
final class VideoFileState {
  const VideoFileState({this.length, this.etag, this.lastModified});

  /// 上游声明的总长度；未声明时为 null。
  final int? length;

  /// 强 `ETag`（弱 ETag 不记录）。
  final String? etag;
  final String? lastModified;

  /// 有校验值时才按区间续传（architecture §4.5.1「续传」）。
  String? get validator => etag ?? lastModified;
}

/// 一条已下载的外挂字幕。
final class VideoSubtitleEntry {
  const VideoSubtitleEntry({
    required this.file,
    this.lang,
    this.format,
    this.charset,
    this.contentType,
  });

  /// 文件名（[videoSubtitleFileName]）。
  final String file;

  /// `SubtitleRef.lang` / `format` / `charset`。
  final String? lang;
  final String? format;
  final String? charset;

  /// 下载时响应的 `Content-Type`（离线解码时按同样的编码规则使用其中的 charset）。
  final String? contentType;
}

/// `video.json`。
final class VideoManifest {
  const VideoManifest._({
    required this.sourceKey,
    required this.label,
    this.bandwidth,
    this.resolution,
    this.codecs,
    this.tracks = const [],
    this.file,
    this.subtitles = const [],
  });

  const VideoManifest.hls({
    required String sourceKey,
    required String label,
    int? bandwidth,
    String? resolution,
    String? codecs,
    required List<VideoTrack> tracks,
    List<VideoSubtitleEntry> subtitles = const [],
  }) : this._(
         sourceKey: sourceKey,
         label: label,
         bandwidth: bandwidth,
         resolution: resolution,
         codecs: codecs,
         tracks: tracks,
         subtitles: subtitles,
       );

  const VideoManifest.file({
    required String sourceKey,
    required String label,
    required VideoFileState file,
    List<VideoSubtitleEntry> subtitles = const [],
  }) : this._(
         sourceKey: sourceKey,
         label: label,
         file: file,
         subtitles: subtitles,
       );

  static const version = 1;

  /// 来源标识（sha256 十六进制）：一致时才沿用已下载的文件。
  final String sourceKey;

  /// 所选清晰度的显示名（播放页的清晰度菜单只列它）。
  final String label;

  /// HLS 变体的属性（重新生成主播放列表用）。
  final int? bandwidth;
  final String? resolution;
  final String? codecs;

  /// HLS 轨道；单文件时为空。
  final List<VideoTrack> tracks;

  /// 单文件；HLS 时为 null。
  final VideoFileState? file;
  final List<VideoSubtitleEntry> subtitles;

  bool get isHls => file == null;

  /// 全部分片文件（HLS）都已写完。
  bool get complete =>
      tracks.every((t) => t.items.every((i) => i.file != null));

  VideoManifest copyWith({
    List<VideoTrack>? tracks,
    VideoFileState? file,
    List<VideoSubtitleEntry>? subtitles,
  }) => VideoManifest._(
    sourceKey: sourceKey,
    label: label,
    bandwidth: bandwidth,
    resolution: resolution,
    codecs: codecs,
    tracks: tracks ?? this.tracks,
    file: file ?? this.file,
    subtitles: subtitles ?? this.subtitles,
  );

  String encode() => jsonEncode({
    'version': version,
    'kind': isHls ? 'hls' : 'file',
    'source': sourceKey,
    'label': label,
    if (isHls) ...{
      'bandwidth': ?bandwidth,
      'resolution': ?resolution,
      'codecs': ?codecs,
      'tracks': [
        for (final t in tracks)
          {
            'type': t.type.name,
            'dir': t.dir,
            'sequence': t.mediaSequence,
            'name': ?t.name,
            'language': ?t.language,
            'items': [
              for (final i in t.items)
                {
                  if (i.init) 'init': true,
                  if (!i.init) 'd': i.duration,
                  if (i.discontinuity) 'disc': true,
                  'f': i.file,
                },
            ],
          },
      ],
    },
    if (file case final f?)
      'file': {
        'length': ?f.length,
        'etag': ?f.etag,
        'lastModified': ?f.lastModified,
      },
    'subtitles': [
      for (final s in subtitles)
        {
          'file': s.file,
          'lang': ?s.lang,
          'format': ?s.format,
          'charset': ?s.charset,
          'contentType': ?s.contentType,
        },
    ],
  });

  static final _key = RegExp(r'^[0-9a-f]{64}$');
  static final _subFile = RegExp(r'^sub-(\d{2})\.(srt|vtt|ass)$');

  static Never _bad(String what) => throw FormatException('video.json: $what');

  static String? _optString(Object? v, String what, {int max = 1024}) {
    if (v == null) return null;
    if (v is! String || v.length > max) _bad(what);
    return v;
  }

  static VideoManifest decode(String text) {
    final json = jsonDecode(text);
    if (json is! Map || json['version'] != version) _bad('版本不符');
    final source = json['source'];
    if (source is! String || !_key.hasMatch(source)) _bad('source');
    final label = json['label'];
    if (label is! String || label.length > 256) _bad('label');
    final subtitles = <VideoSubtitleEntry>[];
    final rawSubs = json['subtitles'];
    if (rawSubs is! List || rawSubs.length > maxVideoSubtitles) {
      _bad('subtitles');
    }
    final seenSubs = <String>{};
    for (final s in rawSubs) {
      if (s is! Map) _bad('subtitle');
      final file = s['file'];
      if (file is! String || !_subFile.hasMatch(file) || !seenSubs.add(file)) {
        _bad('subtitle file');
      }
      subtitles.add(
        VideoSubtitleEntry(
          file: file,
          lang: _optString(s['lang'], 'lang'),
          format: _optString(s['format'], 'format', max: 16),
          charset: _optString(s['charset'], 'charset', max: 64),
          contentType: _optString(s['contentType'], 'contentType', max: 256),
        ),
      );
    }
    switch (json['kind']) {
      case 'file':
        final f = json['file'];
        if (f is! Map) _bad('file');
        final length = f['length'];
        if (length != null && (length is! int || length < 0)) _bad('length');
        return VideoManifest.file(
          sourceKey: source,
          label: label,
          file: VideoFileState(
            length: length as int?,
            etag: _optString(f['etag'], 'etag'),
            lastModified: _optString(f['lastModified'], 'lastModified'),
          ),
          subtitles: subtitles,
        );
      case 'hls':
        final rawTracks = json['tracks'];
        if (rawTracks is! List || rawTracks.isEmpty) _bad('tracks');
        final tracks = <VideoTrack>[];
        final dirs = <String>{};
        var subtitleTracks = 0;
        for (final (n, t) in rawTracks.indexed) {
          if (t is! Map) _bad('track');
          final type = VideoTrackType.values
              .where((v) => v.name == t['type'])
              .firstOrNull;
          if (type == null) _bad('track type');
          // 第一个必须是视频，至多一条音频；目录名必须是该位置生成的形式。
          if ((n == 0) != (type == VideoTrackType.video)) _bad('track order');
          final expected = switch (type) {
            VideoTrackType.subtitles => videoTrackDir(type, subtitleTracks++),
            _ => videoTrackDir(type),
          };
          final dir = t['dir'];
          if (dir != expected || !dirs.add(expected)) _bad('track dir');
          if (subtitleTracks > maxVideoSubtitleTracks) _bad('subtitle tracks');
          final sequence = t['sequence'];
          if (sequence is! int || sequence < 0) _bad('sequence');
          final rawItems = t['items'];
          if (rawItems is! List ||
              rawItems.isEmpty ||
              rawItems.length > 99998) {
            _bad('items');
          }
          final items = <VideoItem>[];
          for (final (i, item) in rawItems.indexed) {
            if (item is! Map) _bad('item');
            final init = item['init'];
            if (init != null && init != true) _bad('init');
            final d = item['d'];
            if (init == true
                ? d != null
                : (d is! num || d < 0 || !d.isFinite)) {
              _bad('duration');
            }
            final disc = item['disc'];
            if (disc != null && disc != true) _bad('disc');
            final file = item['f'];
            if (file != null) {
              if (file is! String) _bad('item file');
              final dot = file.lastIndexOf('.');
              final ext = dot < 0 ? '' : file.substring(dot + 1);
              final allowed = type == VideoTrackType.subtitles
                  ? ext == 'vtt'
                  : videoSegmentExtensions.contains(ext) && ext != 'vtt';
              if (!allowed || file != videoItemFileName(expected, i, ext)) {
                _bad('item file');
              }
            }
            items.add(
              VideoItem(
                init: init == true,
                duration: init == true ? 0 : (d as num).toDouble(),
                discontinuity: disc == true,
                file: file as String?,
              ),
            );
          }
          tracks.add(
            VideoTrack(
              type: type,
              dir: expected,
              mediaSequence: sequence,
              items: items,
              name: _optString(t['name'], 'name', max: 256),
              language: _optString(t['language'], 'language', max: 64),
            ),
          );
        }
        if (tracks.where((t) => t.type == VideoTrackType.audio).length > 1) {
          _bad('audio');
        }
        final bandwidth = json['bandwidth'];
        if (bandwidth != null && (bandwidth is! int || bandwidth < 0)) {
          _bad('bandwidth');
        }
        return VideoManifest.hls(
          sourceKey: source,
          label: label,
          bandwidth: bandwidth as int?,
          resolution: _optString(json['resolution'], 'resolution', max: 32),
          codecs: _optString(json['codecs'], 'codecs', max: 256),
          tracks: tracks,
          subtitles: subtitles,
        );
      default:
        _bad('kind');
    }
  }
}

// ---------------------------------------------------------------------------
// 本地播放列表（离线回放，architecture §4.5.1）

/// 本地会话的播放列表与文件：名称 → HLS 文本 / 文件（相对剧集目录的文件名与用途）。
final class LocalVideoLayout {
  const LocalVideoLayout({
    required this.root,
    required this.playlists,
    required this.files,
  });

  /// 交给播放器的条目名。
  final String root;
  final Map<String, String> playlists;

  /// 名称（即相对剧集目录的文件名）→ (是否为字幕分片, 代理地址中使用的扩展名)。
  final Map<String, (bool, String)> files;
}

/// 由 [m] 生成本地会话的内容：客户端重新生成的 HLS（只含代理会保留的标签，没有 `EXT-X-KEY`——分片已是明文），
/// 地址都是本地文件名。[m] 必须已下载完（[VideoManifest.complete]）。
LocalVideoLayout localVideoLayout(VideoManifest m) {
  if (!m.isHls) {
    return const LocalVideoLayout(
      root: videoFileName,
      playlists: {},
      files: {videoFileName: (false, 'bin')},
    );
  }
  final playlists = <String, String>{};
  final files = <String, (bool, String)>{};
  for (final t in m.tracks) {
    final subtitle = t.type == VideoTrackType.subtitles;
    // 同一子播放列表中的分片用同一个扩展名（FFmpeg 按起播分片的格式检查全部分片）：取第一项的。
    final first = t.items.first.file!;
    final ext = first.substring(first.lastIndexOf('.') + 1);
    final out = StringBuffer()
      ..writeln('#EXTM3U')
      ..writeln('#EXT-X-VERSION:6');
    var target = 1;
    for (final i in t.items) {
      if (!i.init && i.duration.ceil() > target) target = i.duration.ceil();
    }
    out
      ..writeln('#EXT-X-TARGETDURATION:$target')
      ..writeln('#EXT-X-MEDIA-SEQUENCE:${t.mediaSequence}')
      ..writeln('#EXT-X-PLAYLIST-TYPE:VOD');
    for (final i in t.items) {
      final name = i.file!;
      files[name] = (subtitle, ext);
      if (i.init) {
        out.writeln('#EXT-X-MAP:URI="$name"');
        continue;
      }
      if (i.discontinuity) out.writeln('#EXT-X-DISCONTINUITY');
      out
        ..writeln('#EXTINF:${i.duration},')
        ..writeln(name);
    }
    out.writeln('#EXT-X-ENDLIST');
    playlists['${t.dir}/index.m3u8'] = out.toString();
  }
  final master = StringBuffer()
    ..writeln('#EXTM3U')
    ..writeln('#EXT-X-VERSION:6');
  final hasAudio = m.tracks.any((t) => t.type == VideoTrackType.audio);
  final subs = m.tracks.where((t) => t.type == VideoTrackType.subtitles);
  if (hasAudio) {
    master.writeln(
      '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="audio",DEFAULT=YES,'
      'AUTOSELECT=YES,URI="a/index.m3u8"',
    );
  }
  for (final t in subs) {
    final name = _attr(t.name) ?? _attr(t.language) ?? t.dir;
    final lang = _attr(t.language);
    master.writeln(
      '#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="$name",'
      '${lang == null ? '' : 'LANGUAGE="$lang",'}'
      'DEFAULT=NO,AUTOSELECT=NO,URI="${t.dir}/index.m3u8"',
    );
  }
  final attrs = [
    'BANDWIDTH=${m.bandwidth ?? 1}',
    if (m.resolution case final r?
        when RegExp(r'^\d{1,5}x\d{1,5}$').hasMatch(r))
      'RESOLUTION=$r',
    if (m.codecs case final c?
        when RegExp(r'^[A-Za-z0-9.,+-]{1,200}$').hasMatch(c))
      'CODECS="$c"',
    if (hasAudio) 'AUDIO="aud"',
    if (subs.isNotEmpty) 'SUBTITLES="subs"',
  ];
  master
    ..writeln('#EXT-X-STREAM-INF:${attrs.join(',')}')
    ..writeln('v/index.m3u8');
  playlists['index.m3u8'] = master.toString();
  return LocalVideoLayout(
    root: 'index.m3u8',
    playlists: playlists,
    files: files,
  );
}

/// 属性值中的文字：去掉引号、控制字符与换行，最多 64 个字符；为空时为 null。
String? _attr(String? v) {
  if (v == null) return null;
  final s = v.replaceAll(RegExp(r'["\u0000-\u001f\u007f-\u009f  ]'), '').trim();
  if (s.isEmpty) return null;
  return s.length > 64 ? s.substring(0, 64) : s;
}
