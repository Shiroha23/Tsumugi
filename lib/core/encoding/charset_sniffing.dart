/// 响应文本的编码识别（docs/source-spec.md §5「响应文本解码」）。
library;

import 'dart:convert';

import 'text_decoding.dart';

/// 编码从哪里得到。
enum CharsetSource {
  /// 规则 / 脚本显式指定（`charset`）。
  override,

  /// 字节序标记。
  bom,

  /// HTTP `Content-Type` 的 charset 参数。
  header,

  /// HTML `<meta charset>` / `<meta http-equiv="Content-Type">`，或 XML 声明的 encoding。
  meta,

  /// 以上都没有（或都不认识）时的 utf-8。
  fallback,
}

class CharsetDetection {
  const CharsetDetection(this.encoding, this.source);

  /// 规范名，见 [normalizeCharset]。
  final String encoding;
  final CharsetSource source;

  @override
  String toString() => '$encoding (${source.name})';
}

/// 只在响应体的前这么多字节内查找 `<meta>` / XML 声明。
const metaPrescanBytes = 4096;

/// 识别 [bytes] 的编码。顺序：
///
/// 1. [override]（规则 / 脚本显式指定；必须是已知标签，由调用方先校验）；
/// 2. BOM（utf-8 / utf-16le / utf-16be）；
/// 3. [contentType] 中的 charset；
/// 4. HTML / XML 文档（或未给出 Content-Type 时）前 [metaPrescanBytes] 字节内的 `<meta>` / XML 声明；
/// 5. utf-8。
///
/// 不认识的 charset 跳过并通过 [log] 记录，继续下一步。
CharsetDetection detectCharset(
  List<int> bytes, {
  String? contentType,
  String? override,
  void Function(String message)? log,
}) {
  if (override != null) {
    final enc = normalizeCharset(override);
    if (enc != null) return CharsetDetection(enc, CharsetSource.override);
    log?.call('unknown charset override "$override", ignored');
  }
  if (bomEncoding(bytes) case final bom?) {
    return CharsetDetection(bom, CharsetSource.bom);
  }
  final (mime, label) = _parseContentType(contentType);
  if (label != null) {
    final enc = normalizeCharset(label);
    if (enc != null) return CharsetDetection(enc, CharsetSource.header);
    log?.call('unknown Content-Type charset "$label", ignored');
  }
  if (mime == null || mime.contains('html') || mime.contains('xml')) {
    for (final label in _prescan(bytes)) {
      final enc = normalizeCharset(label);
      if (enc == null) {
        log?.call('unknown <meta> charset "$label", ignored');
        continue;
      }
      // HTML 规范：<meta> 声明 utf-16 时按 utf-8（字节能被 ASCII 规则读到就不是 utf-16）。
      return CharsetDetection(switch (enc) {
        'utf-16le' || 'utf-16be' => 'utf-8',
        'x-user-defined' => 'windows-1252',
        _ => enc,
      }, CharsetSource.meta);
    }
  }
  return const CharsetDetection('utf-8', CharsetSource.fallback);
}

/// 识别并解码。非法字节输出 U+FFFD，不抛异常。
String decodeText(
  List<int> bytes, {
  String? contentType,
  String? override,
  void Function(String message)? log,
}) => decodeBytes(
  bytes,
  detectCharset(
    bytes,
    contentType: contentType,
    override: override,
    log: log,
  ).encoding,
);

/// `text/html; charset="GBK"` → (`text/html`, `GBK`)。
(String?, String?) _parseContentType(String? value) {
  if (value == null || value.trim().isEmpty) return (null, null);
  final parts = value.split(';');
  final mime = parts.first.trim().toLowerCase();
  String? charset;
  for (final p in parts.skip(1)) {
    final eq = p.indexOf('=');
    if (eq < 0 || p.substring(0, eq).trim().toLowerCase() != 'charset') {
      continue;
    }
    charset = _unquote(p.substring(eq + 1).trim());
    break;
  }
  return (mime.isEmpty ? null : mime, charset);
}

String _unquote(String s) {
  if (s.length >= 2 &&
      ((s.startsWith('"') && s.endsWith('"')) ||
          (s.startsWith("'") && s.endsWith("'")))) {
    return s.substring(1, s.length - 1).trim();
  }
  return s;
}

final _comment = RegExp(r'<!--[\s\S]*?(-->|$)');
final _meta = RegExp(r'<meta(?=[\s/])([^>]*)>?', caseSensitive: false);
final _attr = RegExp(r'''([^\s"'=/>]+)(?:\s*=\s*("[^"]*"|'[^']*'|[^\s>]+))?''');
final _charsetInContent = RegExp(
  r'''charset\s*=\s*["']?\s*([^\s"';]+)''',
  caseSensitive: false,
);
final _xmlDecl = RegExp(
  r'''^<\?xml\s[^>]*?encoding\s*=\s*["']([^"']+)["']''',
  caseSensitive: false,
);

/// 依次给出文档开头声明的候选 charset 标签（XML 声明，再按出现顺序的 `<meta>`）。
Iterable<String> _prescan(List<int> bytes) sync* {
  final head = latin1.decode(
    bytes.length > metaPrescanBytes
        ? bytes.sublist(0, metaPrescanBytes)
        : bytes,
  );
  if (_xmlDecl.firstMatch(head.trimLeft()) case final m?) yield m.group(1)!;
  for (final m in _meta.allMatches(head.replaceAll(_comment, ''))) {
    final attrs = <String, String>{};
    for (final a in _attr.allMatches(m.group(1)!)) {
      final name = a.group(1)!.toLowerCase();
      attrs.putIfAbsent(name, () => _unquote(a.group(2) ?? ''));
    }
    if (attrs['charset'] case final c? when c.isNotEmpty) {
      yield c;
    } else if (attrs['http-equiv']?.toLowerCase() == 'content-type' &&
        attrs['content'] != null) {
      if (_charsetInContent.firstMatch(attrs['content']!) case final c?) {
        yield _unquote(c.group(1)!);
      }
    }
  }
}
