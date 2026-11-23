import 'hls_playlist.dart';

/// 视频下载用的 HLS 解析（architecture §4.5.1「下载什么」）。
///
/// 与本地媒体代理同一套规则：子播放列表经 [rewriteHlsPlaylist] 解析——只认代理会保留的标签、
/// 地址基于播放列表的最终地址解析、`METHOD=AES-128` 的分片带上 [HlsAes128]（下载时解密）。
/// 代理不解密的加密方式（`SAMPLE-AES` 等）、直播（没有 `EXT-X-ENDLIST`）以 [HlsUnsupportedException] 拒绝。
/// 纯 Dart，不发请求。

/// 播放列表可以解析，但内容不能下载（直播、`SAMPLE-AES`、非 http(s) 地址等），对应 `E_UNSUPPORTED`。
class HlsUnsupportedException implements Exception {
  const HlsUnsupportedException(this.message);

  final String message;

  @override
  String toString() => 'HlsUnsupportedException: $message';
}

/// 主播放列表中的一个变体（`EXT-X-STREAM-INF`）。
final class HlsVariant {
  const HlsVariant({
    required this.uri,
    required this.bandwidth,
    this.resolution,
    this.codecs,
    this.audioGroup,
    this.subtitleGroup,
  });

  final Uri? uri;
  final int bandwidth;
  final String? resolution;
  final String? codecs;
  final String? audioGroup;
  final String? subtitleGroup;
}

/// 主播放列表中的一条 `EXT-X-MEDIA`。
final class HlsRendition {
  const HlsRendition({
    required this.type,
    required this.groupId,
    required this.uri,
    this.name,
    this.language,
    this.isDefault = false,
  });

  /// `AUDIO` / `VIDEO` / `SUBTITLES` / `CLOSED-CAPTIONS`。
  final String type;
  final String groupId;

  /// 没有 `URI` 时为 null（该轨道混在变体的分片中）。
  final Uri? uri;
  final String? name;
  final String? language;
  final bool isDefault;
}

/// 下载时选用的变体与轨道。
final class HlsDownloadSelection {
  const HlsDownloadSelection({
    required this.variant,
    this.audio,
    this.subtitles = const [],
  });

  final HlsVariant variant;

  /// 变体引用的音频组中 `DEFAULT=YES`（没有则第一条）的、有独立播放列表的轨道。
  final HlsRendition? audio;

  /// 变体引用的字幕组中全部有播放列表的轨道。
  final List<HlsRendition> subtitles;
}

/// 解析主播放列表并按 §4.5.1 选择：`BANDWIDTH` 最高的变体（相同时取先出现的），
/// 其音频组的默认轨道与字幕组的全部轨道。不是主播放列表时返回 null。
HlsDownloadSelection? selectHlsDownload(String text, Uri base) {
  final lines = _lines(text);
  final variants = <HlsVariant>[];
  final renditions = <HlsRendition>[];
  Map<String, String>? pending;
  for (final line in lines) {
    if (line.startsWith('#EXT-X-STREAM-INF:')) {
      pending = parseHlsAttributes(line.substring('#EXT-X-STREAM-INF:'.length));
      continue;
    }
    if (line.startsWith('#EXT-X-MEDIA:')) {
      final a = parseHlsAttributes(line.substring('#EXT-X-MEDIA:'.length));
      final type = a['TYPE'];
      final group = a['GROUP-ID'];
      if (type == null || group == null) continue;
      renditions.add(
        HlsRendition(
          type: type,
          groupId: group,
          uri: a['URI'] == null ? null : _resolve(base, a['URI']!),
          name: a['NAME'],
          language: a['LANGUAGE'],
          isDefault: a['DEFAULT'] == 'YES',
        ),
      );
      continue;
    }
    if (line.startsWith('#')) continue;
    if (pending != null) {
      variants.add(
        HlsVariant(
          uri: _resolve(base, line),
          bandwidth: int.tryParse(pending['BANDWIDTH'] ?? '') ?? 0,
          resolution: pending['RESOLUTION'],
          codecs: pending['CODECS'],
          audioGroup: pending['AUDIO'],
          subtitleGroup: pending['SUBTITLES'],
        ),
      );
      pending = null;
    }
  }
  if (variants.isEmpty) return null;
  var best = variants.first;
  for (final v in variants.skip(1)) {
    if (v.bandwidth > best.bandwidth) best = v;
  }
  HlsRendition? audio;
  if (best.audioGroup case final g?) {
    final group = [
      for (final r in renditions)
        if (r.type == 'AUDIO' && r.groupId == g) r,
    ];
    final chosen =
        group.where((r) => r.isDefault).firstOrNull ?? group.firstOrNull;
    if (chosen?.uri != null) audio = chosen;
  }
  final subtitles = <HlsRendition>[
    if (best.subtitleGroup case final g?)
      for (final r in renditions)
        if (r.type == 'SUBTITLES' && r.groupId == g && r.uri != null) r,
  ];
  return HlsDownloadSelection(
    variant: best,
    audio: audio,
    subtitles: subtitles,
  );
}

/// 子播放列表中的一项：初始化分片（`EXT-X-MAP`）或分片。
enum HlsItemKind { init, segment }

final class HlsItem {
  const HlsItem({
    required this.kind,
    required this.uri,
    this.duration = 0,
    this.range,
    this.aes,
    this.discontinuity = false,
  });

  final HlsItemKind kind;
  final Uri uri;

  /// `EXTINF` 时长（秒）；初始化分片为 0。
  final double duration;

  /// 以字节区间引用资源时的 (起点, 长度)。
  final (int, int)? range;

  /// 非 null 时需按 AES-128 解密。
  final HlsAes128? aes;

  /// 该分片之前有 `EXT-X-DISCONTINUITY`。
  final bool discontinuity;
}

/// 可下载的点播子播放列表。
final class HlsMediaPlaylist {
  const HlsMediaPlaylist({required this.mediaSequence, required this.items});

  final int mediaSequence;
  final List<HlsItem> items;

  int get segmentCount =>
      items.where((i) => i.kind == HlsItemKind.segment).length;
}

/// 解析点播子播放列表（[base] 为最终地址）。直播、代理不解密的加密方式、不受支持的地址
/// 抛出 [HlsUnsupportedException]；格式错误（不是播放列表、`EXTINF` 无效）抛出 [FormatException]。
HlsMediaPlaylist parseHlsMediaPlaylist(String text, Uri base) {
  final entries = <(Uri?, HlsUriKind, HlsAes128?, (int, int)?)>[];
  (int, int)? range;
  final out = rewriteHlsPlaylist(
    text,
    base: base,
    onByteRange: (o, n) => range = (o, n),
    map: (uri, kind, [aes]) {
      entries.add((uri, kind, aes, range));
      range = null;
      return '@@${entries.length - 1}@@';
    },
  );
  final lines = _lines(out);
  if (!lines.contains('#EXT-X-ENDLIST')) {
    throw const HlsUnsupportedException('直播流不能下载');
  }
  final mapsIn = _lines(text).where((l) => l.startsWith('#EXT-X-MAP')).length;
  // 原文中的加密方式：rewriteHlsPlaylist 会整行删掉带其他 `…URI=` 属性的标签（如 SAMPLE-AES 的
  // 厂商扩展属性），不能据改写结果判断“没有加密”。
  for (final l in _lines(text)) {
    if (!l.startsWith('#EXT-X-KEY') && !l.startsWith('#EXT-X-SESSION-KEY')) {
      continue;
    }
    final method = RegExp(r'METHOD=([A-Za-z0-9-]+)').firstMatch(l)?[1];
    if (method != 'NONE' && method != 'AES-128') {
      throw HlsUnsupportedException('不支持的加密方式：${method ?? '未知'}');
    }
  }
  var sequence = 0;
  final items = <HlsItem>[];
  double? duration;
  var discontinuity = false;
  var maps = 0;
  (Uri?, HlsUriKind, HlsAes128?, (int, int)?) entryOf(String s) {
    final m = RegExp(r'@@(\d+)@@').firstMatch(s);
    if (m == null) throw const FormatException('播放列表地址无效');
    return entries[int.parse(m[1]!)];
  }

  Uri usable(Uri? uri) {
    if (uri == null ||
        !(uri.scheme == 'http' || uri.scheme == 'https') ||
        uri.host.isEmpty) {
      throw const HlsUnsupportedException('分片地址或加密方式不受支持');
    }
    return uri.removeFragment();
  }

  for (final line in lines) {
    if (line.startsWith('#EXT-X-MEDIA-SEQUENCE:')) {
      sequence = int.tryParse(line.substring(22).trim()) ?? 0;
    } else if (line.startsWith('#EXTINF:')) {
      final v = line.substring(8).split(',').first.trim();
      duration = double.tryParse(v);
      if (duration == null || !duration.isFinite || duration < 0) {
        throw const FormatException('EXTINF 无效');
      }
    } else if (line == '#EXT-X-DISCONTINUITY') {
      discontinuity = true;
    } else if (line.startsWith('#EXT-X-KEY') ||
        line.startsWith('#EXT-X-SESSION-KEY')) {
      // AES-128 的标签已由 rewriteHlsPlaylist 去掉；剩下的是代理不解密的方式。
      final method = RegExp(r'METHOD=([A-Z0-9-]+)').firstMatch(line)?[1];
      if (method != 'NONE') {
        throw HlsUnsupportedException('不支持的加密方式：${method ?? '未知'}');
      }
    } else if (line.startsWith('#EXT-X-MAP:')) {
      final (uri, _, aes, r) = entryOf(line);
      maps++;
      items.add(
        HlsItem(kind: HlsItemKind.init, uri: usable(uri), range: r, aes: aes),
      );
    } else if (!line.startsWith('#')) {
      final (uri, kind, aes, r) = entryOf(line);
      if (kind != HlsUriKind.media) {
        throw const FormatException('子播放列表中出现了播放列表');
      }
      final d = duration;
      if (d == null) throw const FormatException('分片缺少 EXTINF');
      items.add(
        HlsItem(
          kind: HlsItemKind.segment,
          uri: usable(uri),
          duration: d,
          range: r,
          aes: aes,
          discontinuity: discontinuity,
        ),
      );
      duration = null;
      discontinuity = false;
    }
  }
  // 加密但缺少 IV、或带字节区间的加密初始化分片会被 rewriteHlsPlaylist 去掉：不能只下载其余部分。
  if (maps != mapsIn) {
    throw const HlsUnsupportedException('初始化分片的加密方式不受支持');
  }
  if (items.every((i) => i.kind != HlsItemKind.segment)) {
    throw const FormatException('播放列表中没有分片');
  }
  return HlsMediaPlaylist(mediaSequence: sequence, items: items);
}

/// 去掉查询串与片段后的地址（只取协议、主机、端口与路径），用于续传的来源标识（§4.5.1「续传」）：
/// 很多站点的分片地址带有每次都变的签名参数。
String strippedHlsUrl(Uri uri) => Uri(
  scheme: uri.scheme,
  host: uri.host,
  port: uri.port,
  path: uri.path,
).toString();

List<String> _lines(String text) => [
  for (final l in text.split(RegExp(r'\r\n|\r|\n')))
    if (l.trim().isNotEmpty) l.trim(),
];

Uri? _resolve(Uri base, String value) {
  try {
    return base.resolve(value.trim());
  } on FormatException {
    return null;
  }
}
