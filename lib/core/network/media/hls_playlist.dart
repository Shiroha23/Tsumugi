import 'dart:convert';
import 'dart:typed_data';

/// 播放列表中一个地址的用途，决定本地媒体代理如何处理它的响应（architecture §6.4）。
enum HlsUriKind {
  /// 子播放列表（`EXT-X-STREAM-INF` 之后的行、音视频 `EXT-X-MEDIA` / `EXT-X-I-FRAME-STREAM-INF`
  /// / `EXT-X-RENDITION-REPORT` 的 `URI`）。
  playlist,

  /// 字幕子播放列表（`EXT-X-MEDIA:TYPE=SUBTITLES` 的 `URI`），其中的分片为 WebVTT。
  subtitlePlaylist,

  /// 分片、初始化分片（`EXT-X-MAP`）、部分分片（`EXT-X-PART` / `EXT-X-PRELOAD-HINT`）。
  media,

  /// 密钥（`EXT-X-KEY` / `EXT-X-SESSION-KEY`）。
  key,
}

/// 分片的 AES-128 加密参数（`EXT-X-KEY:METHOD=AES-128`，RFC 8216 §5.2）。
///
/// 代理自己解密这类分片，播放器拿到的是明文，因此改写后的播放列表中不再有对应的 `EXT-X-KEY`。
class HlsAes128 {
  const HlsAes128(this.keyUri, this.iv);

  /// 密钥地址；无法解析时为 null。
  final Uri? keyUri;

  /// 16 字节 IV：标签给出的 `IV`，否则为分片的媒体序号（大端）。
  final Uint8List iv;

  @override
  bool operator ==(Object other) =>
      other is HlsAes128 && other.keyUri == keyUri && _sameBytes(other.iv, iv);

  @override
  int get hashCode => Object.hash(keyUri, Object.hashAll(iv));
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// 把 [uri]（无法解析或不受支持时为 null）换成播放器应当请求的地址。
/// [aes] 非 null 时该地址的内容需要由调用方按 AES-128 解密后再交给播放器。
typedef HlsUriMapper = String Function(
  Uri? uri,
  HlsUriKind kind, [
  HlsAes128? aes,
]);

/// 字节是否以 HLS 播放列表开头（可带 UTF-8 BOM 与前导空白）。
bool looksLikeHlsPlaylist(List<int> head) => _startsWithText(head, '#EXTM3U');

/// 字节是否以 WebVTT 文件头开头（可带 UTF-8 BOM）。
bool looksLikeWebVtt(List<int> head) =>
    _startsWithText(head, 'WEBVTT', skipSpace: false);

bool _startsWithText(List<int> head, String tag, {bool skipSpace = true}) {
  var i = 0;
  if (head.length >= 3 &&
      head[0] == 0xEF &&
      head[1] == 0xBB &&
      head[2] == 0xBF) {
    i = 3;
  }
  while (skipSpace && i < head.length && _isSpace(head[i])) {
    i++;
  }
  if (head.length - i < tag.length) return false;
  for (var j = 0; j < tag.length; j++) {
    if (head[i + j] != tag.codeUnitAt(j)) return false;
  }
  return true;
}

bool _isSpace(int b) => b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D;

/// 改写 HLS 播放列表（RFC 8216），让播放器只会请求 [map] 给出的地址。
///
/// - 只保留 [_keptTags] 中的标签（其余标签、普通注释整行删除）：未知标签可能用任意属性名携带地址
///   （如 `EXT-X-DATERANGE` 的 `X-ASSET-LIST`），无法可靠改写；
/// - 每个 URI 行与保留标签中的 `URI="…"` 属性都基于 [base]（播放列表的最终地址，即重定向之后）
///   解析后交给 [map]；改写后仍含有其他 `…URI=` 属性的行同样删除；
/// - `EXT-X-KEY:METHOD=AES-128` 不输出，其后的分片与初始化分片带上 [HlsAes128] 交给 [map]
///   （由代理解密）。AES-128 与 `EXT-X-BYTERANGE` 同时出现时，分片以 null 地址交给 [map]（不支持）。
///   其他加密方式（`SAMPLE-AES` 等）的 `EXT-X-KEY` 原样改写，密钥由播放器经代理取得。
///
/// 输入不是播放列表（首个非空行不是 `#EXTM3U`）时抛出 [FormatException]。
String rewriteHlsPlaylist(
  String text, {
  required Uri base,
  required HlsUriMapper map,
}) {
  final lines = const LineSplitter().convert(
    text.startsWith('﻿') ? text.substring(1) : text,
  );
  final first = lines.indexWhere((l) => l.trim().isNotEmpty);
  if (first < 0 || lines[first].trim() != '#EXTM3U') {
    throw const FormatException('not an HLS playlist');
  }
  final out = <String>[];
  var nextIsPlaylist = false;
  var sequence = 0;
  // 当前生效的 AES-128 密钥：(密钥地址, 显式 IV)；IV 无效时为 (null, null)。
  (Uri?, Uint8List?)? aes;
  var byteRange = false;
  var unsupportedAes = false;

  HlsAes128? aesFor(int seq) => switch (aes) {
    null => null,
    (final key, final iv) => HlsAes128(key, iv ?? _sequenceIv(seq)),
  };

  for (final raw in lines.skip(first)) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (!line.startsWith('#')) {
      final uri = _resolve(base, line);
      if (nextIsPlaylist) {
        out.add(map(uri, HlsUriKind.playlist));
      } else if (aes != null && (byteRange || unsupportedAes)) {
        out.add(map(null, HlsUriKind.media));
      } else {
        out.add(map(uri, HlsUriKind.media, aesFor(sequence)));
      }
      if (!nextIsPlaylist) sequence++;
      nextIsPlaylist = false;
      byteRange = false;
      continue;
    }
    final colon = line.indexOf(':');
    final tag = colon < 0 ? line : line.substring(0, colon);
    if (!_keptTags.contains(tag)) continue;
    if (tag == '#EXT-X-STREAM-INF') nextIsPlaylist = true;
    if (tag == '#EXT-X-MEDIA-SEQUENCE') {
      sequence = int.tryParse(line.substring(colon + 1).trim()) ?? 0;
    }
    if (tag == '#EXT-X-BYTERANGE') byteRange = true;
    if (tag == '#EXT-X-KEY') {
      final method = _attribute(line, 'METHOD');
      if (method == 'NONE') {
        aes = null;
        unsupportedAes = false;
      } else if (method == 'AES-128') {
        final uriValue = _uriAttribute.firstMatch(line)?.group(2);
        final ivText = _attribute(line, 'IV');
        final iv = ivText == null ? null : _parseIv(ivText);
        aes = (uriValue == null ? null : _resolve(base, uriValue), iv);
        // 显式 IV 无法解析、或缺少 URI：之后的分片不支持。
        unsupportedAes = uriValue == null || (ivText != null && iv == null);
        continue; // 由代理解密，不交给播放器
      } else {
        aes = null;
        unsupportedAes = false;
      }
    }
    if (tag == '#EXT-X-MAP' && aes != null) {
      // 加密的初始化分片：按 RFC 8216 必须有显式 IV。
      final (key, iv) = aes;
      final uriValue = _uriAttribute.firstMatch(line)?.group(2);
      if (iv == null || unsupportedAes || uriValue == null) continue;
      if (_attribute(line, 'BYTERANGE') != null) continue;
      out.add(
        '#EXT-X-MAP:URI="${map(_resolve(base, uriValue), HlsUriKind.media, HlsAes128(key, iv))}"',
      );
      continue;
    }
    if (tag == '#EXT-X-PART' && aes != null) continue; // 低延迟分片暂不支持加密
    if (colon < 0) {
      out.add(line);
      continue;
    }
    final kind = switch (tag) {
      '#EXT-X-MEDIA' when _subtitles.hasMatch(line) =>
        HlsUriKind.subtitlePlaylist,
      _ => _uriKindOf[tag] ?? HlsUriKind.media,
    };
    final rewritten = line.replaceAllMapped(
      _uriAttribute,
      (m) => '${m[1]}URI="${map(_resolve(base, m[2]!), kind)}"',
    );
    // 剩下的部分（去掉刚写入的 URI 值）若还有别的 `…URI=` 属性，整行删除。
    final rest = rewritten.replaceAll(_quotedUriAttribute, '');
    if (_anyUriAttribute.hasMatch(rest)) continue;
    out.add(rewritten);
  }
  return '${out.join('\n')}\n';
}

/// 属性值（去掉引号）；没有该属性时为 null。
String? _attribute(String line, String name) {
  final m = RegExp('[:,]$name=("[^"]*"|[^,]*)').firstMatch(line);
  if (m == null) return null;
  final v = m.group(1)!;
  return v.startsWith('"') ? v.substring(1, v.length - 1) : v;
}

/// `0x` 开头、最多 32 位十六进制数，左侧补零为 16 字节；无效时为 null。
Uint8List? _parseIv(String text) {
  final m = RegExp(r'^0[xX]([0-9a-fA-F]{1,32})$').firstMatch(text.trim());
  if (m == null) return null;
  final hex = m.group(1)!.padLeft(32, '0');
  return Uint8List.fromList([
    for (var i = 0; i < 32; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ]);
}

Uint8List _sequenceIv(int sequence) {
  final iv = Uint8List(16);
  var v = sequence;
  for (var i = 15; i >= 8 && v > 0; i--) {
    iv[i] = v & 0xFF;
    v >>= 8;
  }
  return iv;
}

Uri? _resolve(Uri base, String value) {
  try {
    return base.resolve(value.trim());
  } on FormatException {
    return null;
  }
}

/// 属性列表中名为 `URI` 的属性（前面是 `:` 或 `,`，避免匹配 `SERVER-URI`）。
final _uriAttribute = RegExp(r'([:,])URI="([^"]*)"');
final _quotedUriAttribute = RegExp(r'[:,]URI="[^"]*"');
final _anyUriAttribute = RegExp('URI\\s*=', caseSensitive: false);
final _subtitles = RegExp(r'[:,]TYPE=SUBTITLES(,|$)');

/// 保留的标签：RFC 8216 中播放器需要、且地址只出现在 `URI` 属性或下一行的标签。
/// 不保留：`EXT-X-DATERANGE`（插播广告等用任意属性携带地址）、`EXT-X-SESSION-DATA`、
/// `EXT-X-CONTENT-STEERING`、`EXT-X-DEFINE`（变量替换会改变地址）、`EXT-X-SKIP` 以及非标准标签。
const _keptTags = {
  '#EXTM3U',
  '#EXT-X-VERSION',
  '#EXT-X-INDEPENDENT-SEGMENTS',
  '#EXT-X-START',
  '#EXTINF',
  '#EXT-X-BYTERANGE',
  '#EXT-X-DISCONTINUITY',
  '#EXT-X-KEY',
  '#EXT-X-MAP',
  '#EXT-X-PROGRAM-DATE-TIME',
  '#EXT-X-GAP',
  '#EXT-X-BITRATE',
  '#EXT-X-PART',
  '#EXT-X-TARGETDURATION',
  '#EXT-X-MEDIA-SEQUENCE',
  '#EXT-X-DISCONTINUITY-SEQUENCE',
  '#EXT-X-ENDLIST',
  '#EXT-X-PLAYLIST-TYPE',
  '#EXT-X-I-FRAMES-ONLY',
  '#EXT-X-PART-INF',
  '#EXT-X-SERVER-CONTROL',
  '#EXT-X-PRELOAD-HINT',
  '#EXT-X-RENDITION-REPORT',
  '#EXT-X-MEDIA',
  '#EXT-X-STREAM-INF',
  '#EXT-X-I-FRAME-STREAM-INF',
  '#EXT-X-SESSION-KEY',
};

const _uriKindOf = {
  '#EXT-X-KEY': HlsUriKind.key,
  '#EXT-X-SESSION-KEY': HlsUriKind.key,
  '#EXT-X-MEDIA': HlsUriKind.playlist,
  '#EXT-X-I-FRAME-STREAM-INF': HlsUriKind.playlist,
  '#EXT-X-RENDITION-REPORT': HlsUriKind.playlist,
  '#EXT-X-MAP': HlsUriKind.media,
  '#EXT-X-PART': HlsUriKind.media,
  '#EXT-X-PRELOAD-HINT': HlsUriKind.media,
};
