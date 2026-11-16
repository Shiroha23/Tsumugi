/// 外挂字幕（srt / vtt / ass）的解码、格式识别与解析（architecture §6.4.7）。
///
/// 只取时间与文字：样式、位置、特效、内嵌字体与绘图指令都被忽略。字幕文件来自第三方源，
/// 属于不可信输入：格式按内容识别、条数与单条长度有上限，解析失败抛 [SubtitleFormatException]。
library;

import 'dart:convert';

import '../encoding/charset_sniffing.dart';
import '../encoding/text_decoding.dart';

enum SubtitleFormat {
  srt,
  vtt,
  ass;

  /// `SubtitleRef.format` 的取值（不区分大小写；`ssa` 视为 ass）；不认识的返回 null。
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
    : cues = List.unmodifiable(cues),
      _maxLength = cues.fold(
        Duration.zero,
        (m, c) => c.end - c.start > m ? c.end - c.start : m,
      );

  final SubtitleFormat format;
  final List<SubtitleCue> cues;
  final Duration _maxLength;

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
    final active = <String>[];
    // 往前找：开始时间早于 position - 最长时长的不可能还在显示。
    final earliest = position - _maxLength;
    for (var i = lo - 1; i >= 0 && cues[i].start >= earliest; i--) {
      if (cues[i].end > position) active.add(cues[i].text);
    }
    return active.reversed.join('\n');
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

/// srt / vtt 文字中的标签：HTML 风格的 `<…>` 与 ASS 风格的 `{\…}`。
final _tags = RegExp(r'<[^>\n]*>|\{\\[^}\n]*\}');

String _stripMarkup(String s) => _decodeEntities(s.replaceAll(_tags, ''));

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

final _assOverride = RegExp(r'\{([^}]*)\}');
final _assDrawing = RegExp(r'\\p(\d+)');

/// 去掉 `{…}` 覆盖标签；`\N` / `\n` 为换行，`\h` 为空格；绘图模式（`\p1` 起到 `\p0`）中的内容丢弃。
String _assText(String s) {
  final out = StringBuffer();
  var drawing = false;
  var from = 0;
  for (final m in _assOverride.allMatches(s)) {
    if (!drawing) out.write(s.substring(from, m.start));
    for (final p in _assDrawing.allMatches(m[1]!)) {
      // 位数过多（溢出）也按绘图模式处理。
      drawing = (int.tryParse(p[1]!) ?? 1) > 0;
    }
    from = m.end;
  }
  if (!drawing) out.write(s.substring(from));
  return out
      .toString()
      .replaceAll(r'\N', '\n')
      .replaceAll(r'\n', '\n')
      .replaceAll(r'\h', '\u00A0');
}
