/// 外挂字幕（srt / vtt / ass）的解码、格式识别与解析（architecture §6.4.7）。
///
/// 只取时间与文字：样式、位置、特效、内嵌字体与绘图指令都被忽略。字幕文件来自第三方源，
/// 属于不可信输入：格式按内容识别、条数与单条长度有上限，解析失败抛 [SubtitleFormatException]。
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../encoding/charset_sniffing.dart';
import '../encoding/text_decoding.dart';

enum SubtitleFormat {
  srt,
  vtt,
  ass;

  /// `SubtitleRef.format` 的取值（不区分大小写；`ssa` 视为 ass）；不认识的返回 null。
  /// 空串与 null 都视为未给出，由调用方（[isBlank]）区分。
  static bool isBlank(String? value) => value == null || value.trim().isEmpty;

  static SubtitleFormat? parse(String? value) =>
      switch (value?.trim().toLowerCase()) {
        'srt' => srt,
        'vtt' || 'webvtt' => vtt,
        'ass' || 'ssa' => ass,
        _ => null,
      };
}

/// 字幕文件不可用（编码、格式、大小或内容）。[message] 面向用户。
class SubtitleFormatException implements Exception {
  const SubtitleFormatException(this.message);

  final String message;

  @override
  String toString() => 'SubtitleFormatException: $message';
}

/// 一条字幕：[start] ≤ 时间 < [end] 时显示 [text]（可含换行）。
class SubtitleCue {
  const SubtitleCue(this.start, this.end, this.text);

  final Duration start;
  final Duration end;
  final String text;

  @override
  bool operator ==(Object other) =>
      other is SubtitleCue &&
      other.start == start &&
      other.end == end &&
      other.text == text;

  @override
  int get hashCode => Object.hash(start, end, text);

  @override
  String toString() => 'SubtitleCue($start, $end, ${jsonEncode(text)})';
}

/// 解析后的字幕：[cues] 按开始时间排序。
class SubtitleDocument {
  SubtitleDocument(this.format, List<SubtitleCue> cues)
    : cues = List.unmodifiable(cues) {
    while (_leaves < cues.length) {
      _leaves <<= 1;
    }
    _maxEnd = Int64List(2 * _leaves)..fillRange(0, 2 * _leaves, -1);
    for (var i = 0; i < cues.length; i++) {
      _maxEnd[_leaves + i] = cues[i].end.inMicroseconds;
    }
    for (var n = _leaves - 1; n >= 1; n--) {
      _maxEnd[n] = max(_maxEnd[2 * n], _maxEnd[2 * n + 1]);
    }
  }

  final SubtitleFormat format;
  final List<SubtitleCue> cues;

  /// 结束时间（微秒）的最大值线段树：查询只走向仍可能在显示的条目，耗时与结果数成比例
  /// （审查意见：一条很长的 cue 不能让每次查询回扫全部条目）。
  var _leaves = 1;
  late final Int64List _maxEnd;

  /// [position] 时应显示的文字（多条同时显示时按开始时间以换行连接），没有时为空串。
  String textAt(Duration position) {
    // 第一条开始时间 > position 的下标。
    var lo = 0, hi = cues.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (cues[mid].start <= position) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    final active = <int>[];
    _collect(1, 0, _leaves, lo, position.inMicroseconds, active);
    return [for (final i in active) cues[i].text].join('\n');
  }

  /// 在节点 [node]（覆盖 [from, to)）中按下标顺序收集 `< limit` 且结束时间 > [at] 的条目。
  void _collect(int node, int from, int to, int limit, int at, List<int> out) {
    if (from >= limit || _maxEnd[node] <= at) return;
    if (to - from == 1) {
      out.add(from);
      return;
    }
    final mid = (from + to) >> 1;
    _collect(2 * node, from, mid, limit, at, out);
    _collect(2 * node + 1, mid, to, limit, at, out);
  }
}

/// 字幕文件大小上限（字节）。
const maxSubtitleBytes = 4 * 1024 * 1024;

/// 最多保留的条数。
const maxSubtitleCues = 20000;

/// 单条文字的最大长度（字符），超出截断。
const maxSubtitleCueLength = 2000;

/// 把字幕文件的字节解码为文本（source-spec §2.2「视频字幕」）：[charset]（源声明）→ BOM →
/// [contentType] 的 charset → 合法 UTF-8 → GB18030。含 U+0000 时拒绝（二进制或编码不符）。
String decodeSubtitle(
  List<int> bytes, {
  String? charset,
  String? contentType,
  void Function(String message)? log,
}) {
  final detected = detectCharset(
    bytes,
    override: charset,
    // 未给出 Content-Type 时按纯文本：字幕中没有 HTML <meta>，不做 HTML 预扫描。
    contentType: contentType ?? 'text/plain',
    log: log,
  );
  var encoding = detected.encoding;
  if (detected.source == CharsetSource.fallback && !_isUtf8(bytes)) {
    encoding = 'gb18030';
  }
  final text = decodeBytes(bytes, encoding);
  if (text.contains('\u0000')) {
    throw const SubtitleFormatException('字幕文件不是文本');
  }
  return text;
}

bool _isUtf8(List<int> bytes) {
  try {
    utf8.decode(bytes);
    return true;
  } on FormatException {
    return false;
  }
}

/// 按内容识别格式（见 [parseSubtitle]），识别不了时返回 null。
SubtitleFormat? sniffSubtitleFormat(String text) {
  final t = _stripBom(text).trimLeft();
  if (RegExp(r'^WEBVTT(?:[ \t\r\n]|$)').hasMatch(t)) return SubtitleFormat.vtt;
  if (t.toLowerCase().startsWith('[script info]')) return SubtitleFormat.ass;
  final lines = t.split(_newline).take(2).map((l) => l.trim()).toList();
  if (lines.isEmpty) return null;
  if (_srtTiming.hasMatch(lines.first)) return SubtitleFormat.srt;
  if (lines.length == 2 &&
      RegExp(r'^\d+$').hasMatch(lines[0]) &&
      _srtTiming.hasMatch(lines[1])) {
    return SubtitleFormat.srt;
  }
  return null;
}

/// 解析字幕文本。格式按内容识别（不信任扩展名与 `Content-Type`）；[declared]（`SubtitleRef.format`）
/// 给出时必须与识别结果一致。识别不了、不一致或没有任何有效条目时抛 [SubtitleFormatException]。
SubtitleDocument parseSubtitle(String text, {SubtitleFormat? declared}) {
  final format = sniffSubtitleFormat(text);
  if (format == null) {
    throw const SubtitleFormatException('无法识别的字幕格式');
  }
  if (declared != null && declared != format) {
    throw SubtitleFormatException(
      '字幕格式与声明不符（声明 ${declared.name}，实际 ${format.name}）',
    );
  }
  final body = _stripBom(text);
  final cues = switch (format) {
    SubtitleFormat.srt => _parseSrt(body),
    SubtitleFormat.vtt => _parseVtt(body),
    SubtitleFormat.ass => _parseAss(body),
  };
  if (cues.isEmpty) throw const SubtitleFormatException('字幕文件中没有有效的字幕');
  // 稳定排序：同一开始时间保持文件中的顺序。
  final indexed = cues.indexed.toList()
    ..sort((a, b) {
      final c = a.$2.start.compareTo(b.$2.start);
      return c != 0 ? c : a.$1.compareTo(b.$1);
    });
  return SubtitleDocument(format, [for (final (_, c) in indexed) c]);
}

/// WebVTT \u5934\u90E8\u7684 `X-TIMESTAMP-MAP`\uFF08RFC 8216 \u00A73.5\uFF09\uFF1Acue \u65F6\u95F4 [local] \u5BF9\u5E94 MPEG-TS \u65F6\u95F4 [mpegts]\uFF0890 kHz\uFF09\u3002
class WebVttTimestampMap {
  const WebVttTimestampMap(this.local, this.mpegts);

  final Duration local;

  /// 33 \u4F4D PES \u65F6\u95F4\u6233\uFF08\u5DF2\u5BF9 2\u00B3\u00B3 \u53D6\u6A21\uFF09\u3002
  final int mpegts;

  @override
  bool operator ==(Object other) =>
      other is WebVttTimestampMap &&
      other.local == local &&
      other.mpegts == mpegts;

  @override
  int get hashCode => Object.hash(local, mpegts);

  @override
  String toString() => 'WebVttTimestampMap($local, $mpegts)';
}

/// HLS \u5B57\u5E55\u8F68\u7684\u4E00\u4E2A WebVTT \u5206\u7247\uFF1A[cues] \u4E3A\u5206\u7247\u5185\u7684\u65F6\u95F4\uFF08\u672A\u6362\u7B97\uFF09\uFF0C\u6309\u6587\u4EF6\u4E2D\u7684\u987A\u5E8F\uFF1B\u53EF\u4EE5\u4E3A\u7A7A\u3002
class WebVttSegment {
  const WebVttSegment(this.cues, this.timestampMap);

  final List<SubtitleCue> cues;

  /// \u5934\u90E8\u6CA1\u6709\uFF08\u6216\u65E0\u6CD5\u89E3\u6790\uFF09`X-TIMESTAMP-MAP` \u65F6\u4E3A null\u3002
  final WebVttTimestampMap? timestampMap;
}

/// \u89E3\u6790 HLS \u5B57\u5E55\u8F68\u7684\u4E00\u4E2A\u5206\u7247\uFF08architecture \u00A76.4.7\u300CHLS \u5B57\u5E55\u8F68\u300D\uFF09\uFF1A\u4E0E [parseSubtitle] \u7684 WebVTT \u89C4\u5219\u76F8\u540C\uFF0C
/// \u4F46\u6CA1\u6709 cue \u4E0D\u7B97\u9519\u8BEF\uFF08HLS \u4E2D\u5E38\u89C1\u7A7A\u5206\u7247\uFF09\uFF0C\u5E76\u8BFB\u53D6\u5934\u90E8\u7684 `X-TIMESTAMP-MAP`\u3002
/// \u4E0D\u4EE5 `WEBVTT` \u5F00\u5934\u65F6\u629B [SubtitleFormatException]\u3002
WebVttSegment parseWebVttSegment(String text) {
  final body = _stripBom(text);
  if (sniffSubtitleFormat(body) != SubtitleFormat.vtt) {
    throw const SubtitleFormatException(
      '\u5B57\u5E55\u5206\u7247\u4E0D\u662F WebVTT',
    );
  }
  WebVttTimestampMap? map;
  final header = _blocks(body.trimLeft()).firstOrNull ?? const <String>[];
  for (final line in header.skip(1)) {
    final t = line.trim();
    if (t.startsWith(_timestampMapHeader)) {
      map = _timestampMap(t.substring(_timestampMapHeader.length));
      break;
    }
  }
  return WebVttSegment(_parseVtt(body), map);
}

const _timestampMapHeader = 'X-TIMESTAMP-MAP=';
final _vttTimeOnly = RegExp('^$_vttTime\$');
final _mpegTsDigits = RegExp(r'^\d{1,18}$');

/// `LOCAL:<cue \u65F6\u95F4>,MPEGTS:<\u6574\u6570>`\uFF08\u4E24\u9879\u987A\u5E8F\u4E0D\u9650\uFF09\uFF1B\u7F3A\u9879\u6216\u65E0\u6548\u65F6\u4E3A null\u3002
WebVttTimestampMap? _timestampMap(String value) {
  Duration? local;
  int? mpegts;
  for (final part in value.split(',')) {
    final p = part.trim();
    if (p.startsWith('LOCAL:')) {
      final m = _vttTimeOnly.firstMatch(p.substring(6).trim());
      if (m != null) local = _time(m[1], m[2], m[3], m[4], 3);
    } else if (p.startsWith('MPEGTS:')) {
      final digits = p.substring(7).trim();
      if (_mpegTsDigits.hasMatch(digits)) {
        mpegts = int.parse(digits) % mpegTsWrap;
      }
    }
  }
  if (local == null || mpegts == null) return null;
  return WebVttTimestampMap(local, mpegts);
}

/// MPEG-TS \u65F6\u95F4\u6233\uFF0890 kHz\uFF09\u7684\u56DE\u7ED5\u5468\u671F\uFF1A2\u00B3\u00B3\u3002
const mpegTsWrap = 1 << 33;

String _stripBom(String s) => s.startsWith('\uFEFF') ? s.substring(1) : s;

final _newline = RegExp(r'\r\n|\r|\n');

/// srt 的时间：`[H…:]MM:SS[,.]mmm`（小时可省略、毫秒 1–3 位）。
const _srtTime = r'(?:(\d+):)?(\d{1,2}):(\d{1,2})[,.](\d{1,3})';
final _srtTiming = RegExp('^$_srtTime\\s*-->\\s*$_srtTime');

/// vtt 的时间：`[HH:]MM:SS.mmm`。
const _vttTime = r'(?:(\d+):)?(\d{2}):(\d{2})\.(\d{3})';
final _vttTiming = RegExp('^$_vttTime[ \\t]+-->[ \\t]+$_vttTime(?:[ \\t]|\$)');

Duration? _time(String? h, String? m, String? s, String? frac, int fracDigits) {
  final hours = h == null ? 0 : int.tryParse(h);
  final minutes = int.tryParse(m ?? '');
  final seconds = int.tryParse(s ?? '');
  final f = int.tryParse(frac ?? '');
  if (hours == null || minutes == null || seconds == null || f == null) {
    return null;
  }
  if (minutes > 59 || seconds > 59 || hours > 99999) return null;
  // 毫秒位数不足 3 位时按小数处理（",5" = 500 ms）。
  final ms = switch (fracDigits) {
    1 => f * 100,
    2 => f * 10,
    _ => f,
  };
  return Duration(
    hours: hours,
    minutes: minutes,
    seconds: seconds,
    milliseconds: ms,
  );
}

(Duration, Duration)? _timing(RegExpMatch m) {
  final start = _time(m[1], m[2], m[3], m[4], m[4]!.length);
  final end = _time(m[5], m[6], m[7], m[8], m[8]!.length);
  if (start == null || end == null || end <= start) return null;
  return (start, end);
}

/// 收集有效条目：文字为空或时间无效的丢弃，超过 [maxSubtitleCues] 的忽略。
class _Cues {
  final list = <SubtitleCue>[];

  bool get full => list.length >= maxSubtitleCues;

  void add(Duration start, Duration end, String text) {
    if (full) return;
    final t = _tidy(text);
    if (t.isEmpty) return;
    list.add(SubtitleCue(start, end, t));
  }
}

/// 去掉每行首尾空白与空行，限制长度。
String _tidy(String text) {
  final lines = text
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .join('\n');
  return lines.length > maxSubtitleCueLength
      ? lines.substring(0, maxSubtitleCueLength)
      : lines;
}

/// 按空行切块（每块为若干非空行）。
Iterable<List<String>> _blocks(String text) sync* {
  var block = <String>[];
  for (final line in text.split(_newline)) {
    if (line.trim().isEmpty) {
      if (block.isNotEmpty) yield block;
      block = <String>[];
    } else {
      block.add(line);
    }
  }
  if (block.isNotEmpty) yield block;
}

// ---------------------------------------------------------------------------
// srt

List<SubtitleCue> _parseSrt(String text) {
  final out = _Cues();
  for (final block in _blocks(text)) {
    if (out.full) break;
    // 时间轴在第一行或第二行（第一行为序号）。
    var i = 0;
    RegExpMatch? m = _srtTiming.firstMatch(block[0].trim());
    if (m == null && block.length > 1) {
      m = _srtTiming.firstMatch(block[1].trim());
      i = 1;
    }
    if (m == null) continue;
    final t = _timing(m);
    if (t == null) continue;
    out.add(t.$1, t.$2, _stripMarkup(block.sublist(i + 1).join('\n')));
  }
  return out.list;
}

/// 去掉 srt / vtt 文字中的标签（HTML 风格的 `<…>` 与 ASS 风格的 `{\…}`，都不跨行），再解码字符实体。
///
/// 手写的线性扫描（审查意见：正则在大量未闭合的 `<` / `{` 上耗时超平方）：从某个开头找不到同一行内的
/// 结尾时，记下“到这里为止都没有结尾”，其后的同类开头直接当作普通文字，每个字符最多被扫描常数次。
String _stripMarkup(String s) {
  final out = StringBuffer();
  var noAngleCloseBefore = -1; // 在此下标之前（同一行）没有 '>'
  var noBraceCloseBefore = -1; // 在此下标之前（同一行）没有 '}'
  var literalFrom = 0;
  var i = 0;
  while (i < s.length) {
    final c = s.codeUnitAt(i);
    final isAngle = c == 0x3C; // <
    final isBrace =
        c == 0x7B && i + 1 < s.length && s.codeUnitAt(i + 1) == 0x5C; // `{\`
    if (!isAngle && !isBrace) {
      i++;
      continue;
    }
    if ((isAngle && i < noAngleCloseBefore) ||
        (isBrace && i < noBraceCloseBefore)) {
      i++;
      continue;
    }
    final close = isAngle ? 0x3E : 0x7D;
    var j = i + 1;
    while (j < s.length) {
      final d = s.codeUnitAt(j);
      if (d == close || d == 0x0A) break;
      j++;
    }
    if (j < s.length && s.codeUnitAt(j) == close) {
      out.write(s.substring(literalFrom, i));
      i = j + 1;
      literalFrom = i;
    } else {
      if (isAngle) {
        noAngleCloseBefore = j;
      } else {
        noBraceCloseBefore = j;
      }
      i++;
    }
  }
  out.write(s.substring(literalFrom));
  return _decodeEntities(out.toString());
}

final _entity = RegExp(
  r'&(amp|lt|gt|quot|apos|nbsp|lrm|rlm|#\d{1,7}|#x[0-9a-fA-F]{1,6});',
);

String _decodeEntities(String s) => s.replaceAllMapped(_entity, (m) {
  final name = m[1]!;
  switch (name) {
    case 'amp':
      return '&';
    case 'lt':
      return '<';
    case 'gt':
      return '>';
    case 'quot':
      return '"';
    case 'apos':
      return "'";
    case 'nbsp':
      return '\u00A0';
    case 'lrm':
      return '\u200E';
    case 'rlm':
      return '\u200F';
  }
  final code = name.startsWith('#x')
      ? int.tryParse(name.substring(2), radix: 16)
      : int.tryParse(name.substring(1));
  // 控制字符、代理项与超出范围的码点不解码。
  if (code == null ||
      code < 0x20 ||
      code > 0x10FFFF ||
      (code >= 0xD800 && code <= 0xDFFF)) {
    return m[0]!;
  }
  return String.fromCharCode(code);
});

// ---------------------------------------------------------------------------
// vtt

List<SubtitleCue> _parseVtt(String text) {
  final out = _Cues();
  var first = true;
  for (final block in _blocks(text)) {
    if (out.full) break;
    // 第一块是 WEBVTT 头（及其后的头部行）。
    if (first) {
      first = false;
      if (block[0].trimLeft().startsWith('WEBVTT')) continue;
    }
    final head = block[0].trim();
    if (head.startsWith('NOTE') ||
        head.startsWith('STYLE') ||
        head.startsWith('REGION')) {
      continue;
    }
    // 时间轴在第一行，或第二行（第一行为标识）。
    var i = 0;
    RegExpMatch? m = _vttTiming.firstMatch(head);
    if (m == null && block.length > 1) {
      m = _vttTiming.firstMatch(block[1].trim());
      i = 1;
    }
    if (m == null) continue;
    final t = _timing(m);
    if (t == null) continue;
    out.add(t.$1, t.$2, _stripMarkup(block.sublist(i + 1).join('\n')));
  }
  return out.list;
}

// ---------------------------------------------------------------------------
// ass / ssa

List<SubtitleCue> _parseAss(String text) {
  final out = _Cues();
  var inEvents = false;
  List<String>? format;
  for (final raw in text.split(_newline)) {
    if (out.full) break;
    final line = raw.trim();
    if (line.startsWith('[') && line.endsWith(']')) {
      // [Fonts] / [Graphics] 等段整段跳过（不解码内嵌数据）。
      inEvents = line.toLowerCase() == '[events]';
      continue;
    }
    if (!inEvents) continue;
    final colon = line.indexOf(':');
    if (colon < 0) continue;
    final key = line.substring(0, colon).trim().toLowerCase();
    final value = line.substring(colon + 1);
    if (key == 'format') {
      format = [for (final f in value.split(',')) f.trim().toLowerCase()];
      continue;
    }
    if (key != 'dialogue') continue; // Comment 等
    final fields = format ?? _defaultAssFormat;
    final textIndex = fields.indexOf('text');
    final startIndex = fields.indexOf('start');
    final endIndex = fields.indexOf('end');
    // Text 必须是最后一列（其中可以有逗号）。
    if (textIndex != fields.length - 1 || startIndex < 0 || endIndex < 0) {
      continue;
    }
    final parts = _splitN(value, fields.length);
    if (parts == null) continue;
    final start = _assTime(parts[startIndex]);
    final end = _assTime(parts[endIndex]);
    if (start == null || end == null || end <= start) continue;
    out.add(start, end, _assText(parts[textIndex]));
  }
  return out.list;
}

const _defaultAssFormat = [
  'layer',
  'start',
  'end',
  'style',
  'name',
  'marginl',
  'marginr',
  'marginv',
  'effect',
  'text',
];

/// 按逗号切成 [n] 段，最后一段包含其余全部内容；段数不足时返回 null。
List<String>? _splitN(String s, int n) {
  final out = <String>[];
  var from = 0;
  for (var i = 0; i < n - 1; i++) {
    final comma = s.indexOf(',', from);
    if (comma < 0) return null;
    out.add(s.substring(from, comma));
    from = comma + 1;
  }
  out.add(s.substring(from));
  return out;
}

final _assTimeRe = RegExp(r'^(\d+):(\d{1,2}):(\d{1,2})(?:\.(\d{1,3}))?$');

/// `H:MM:SS.cc`（百分之一秒）。
Duration? _assTime(String s) {
  final m = _assTimeRe.firstMatch(s.trim());
  if (m == null) return null;
  final frac = m[4] ?? '0';
  return _time(m[1], m[2], m[3], frac, frac.length);
}

final _assDrawing = RegExp(r'\p(\d+)');

/// 去掉 `{…}` 覆盖标签；`\N` 为换行，`\n`（软换行，只在 WrapStyle 2 下换行）与 `\h` 为空格；
/// 绘图模式（`\p1` 起到 `\p0`）中的内容丢弃。线性扫描：没有 `}` 的 `{` 之后全部按普通文字处理。
String _assText(String s) {
  final out = StringBuffer();
  var drawing = false;
  var from = 0;
  while (true) {
    final open = s.indexOf('{', from);
    final close = open < 0 ? -1 : s.indexOf('}', open + 1);
    if (close < 0) break; // 其后没有完整的覆盖标签
    if (!drawing) out.write(s.substring(from, open));
    for (final p in _assDrawing.allMatches(s.substring(open + 1, close))) {
      // 位数过多（溢出）也按绘图模式处理。
      drawing = (int.tryParse(p[1]!) ?? 1) > 0;
    }
    from = close + 1;
  }
  if (!drawing) out.write(s.substring(from));
  return out
      .toString()
      .replaceAll(r'\N', '\n')
      .replaceAll(r'\n', ' ')
      .replaceAll(r'\h', '\u00A0');
}
