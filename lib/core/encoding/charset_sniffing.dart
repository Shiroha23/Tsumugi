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

final _charsetInContent = RegExp(
  r"""charset\s*=\s*["']?\s*([^\s"';]+)""",
  caseSensitive: false,
);
final _xmlDecl = RegExp(
  r"""^<\?xml\s[^>]*?encoding\s*=\s*["']([^"']+)["']""",
  caseSensitive: false,
);

/// 依次给出文档开头声明的候选 charset 标签（XML 声明，再按出现顺序的 `<meta>`）。
///
/// 按 HTML 规范的预扫描算法逐个读取标签：注释、`<!` / `<?` 声明整体跳过，其他标签的属性按引号
/// 解析后丢弃，因此属性值中的 `>` 或 `<meta` 不会被误认。
Iterable<String> _prescan(List<int> bytes) sync* {
  final head = latin1.decode(
    bytes.length > metaPrescanBytes
        ? bytes.sublist(0, metaPrescanBytes)
        : bytes,
  );
  if (_xmlDecl.firstMatch(head.trimLeft()) case final m?) yield m.group(1)!;
  final scanner = _TagScanner(head);
  for (var tag = scanner.nextTag(); tag != null; tag = scanner.nextTag()) {
    if (tag.name != 'meta') continue;
    final attrs = tag.attributes;
    if (attrs['charset'] case final c? when c.trim().isNotEmpty) {
      yield c.trim();
    } else if (attrs['http-equiv']?.trim().toLowerCase() == 'content-type' &&
        attrs['content'] != null) {
      if (_charsetInContent.firstMatch(attrs['content']!) case final c?) {
        yield _unquote(c.group(1)!);
      }
    }
  }
}

class _Tag {
  _Tag(this.name, this.attributes);

  /// 小写标签名；结束标签以 `/` 开头。
  final String name;

  /// 小写属性名 → 值，同名属性只保留第一个。
  final Map<String, String> attributes;
}

/// 简化的 HTML 标签扫描器（只用于编码预扫描）。
class _TagScanner {
  _TagScanner(this._s);

  final String _s;
  var _i = 0;

  bool _isSpace(int c) =>
      c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0C || c == 0x0D;

  bool _isAlpha(int c) => (c | 0x20) >= 0x61 && (c | 0x20) <= 0x7A;

  /// 下一个开始 / 结束标签；到达末尾返回 null。
  _Tag? nextTag() {
    final s = _s;
    while (true) {
      final lt = s.indexOf('<', _i);
      if (lt < 0 || lt + 1 >= s.length) {
        _i = s.length;
        return null;
      }
      _i = lt + 1;
      if (s.startsWith('!--', _i)) {
        final end = s.indexOf('-->', _i + 3);
        _i = end < 0 ? s.length : end + 3;
        continue;
      }
      final c = s.codeUnitAt(_i);
      final closing = c == 0x2F; // '/'
      if (closing && _i + 1 < s.length && _isAlpha(s.codeUnitAt(_i + 1))) {
        _i++;
      } else if (!_isAlpha(c)) {
        if (c == 0x21 || c == 0x3F || closing) {
          // <!…>、<?…>、</非字母…>：跳到下一个 '>'。
          final end = s.indexOf('>', _i);
          _i = end < 0 ? s.length : end + 1;
        }
        continue;
      }
      final nameStart = _i;
      while (_i < s.length &&
          !_isSpace(s.codeUnitAt(_i)) &&
          s.codeUnitAt(_i) != 0x2F &&
          s.codeUnitAt(_i) != 0x3E) {
        _i++;
      }
      final name = s.substring(nameStart, _i).toLowerCase();
      final attrs = <String, String>{};
      for (var a = _attribute(); a != null; a = _attribute()) {
        attrs.putIfAbsent(a.$1, () => a!.$2);
      }
      return _Tag(closing ? '/$name' : name, attrs);
    }
  }

  /// 读取一个属性；遇到 '>' 或末尾时返回 null（并越过 '>'）。
  (String, String)? _attribute() {
    final s = _s;
    while (_i < s.length &&
        (_isSpace(s.codeUnitAt(_i)) || s.codeUnitAt(_i) == 0x2F)) {
      _i++;
    }
    if (_i >= s.length) return null;
    if (s.codeUnitAt(_i) == 0x3E) {
      _i++;
      return null;
    }
    final nameStart = _i;
    while (_i < s.length) {
      final c = s.codeUnitAt(_i);
      if (_isSpace(c) || c == 0x2F || c == 0x3E) break;
      if (c == 0x3D && _i > nameStart) break; // '='（名称首字符可以是 '='）
      _i++;
    }
    final name = s.substring(nameStart, _i).toLowerCase();
    while (_i < s.length && _isSpace(s.codeUnitAt(_i))) {
      _i++;
    }
    if (_i >= s.length || s.codeUnitAt(_i) != 0x3D) return (name, '');
    _i++; // '='
    while (_i < s.length && _isSpace(s.codeUnitAt(_i))) {
      _i++;
    }
    if (_i >= s.length) return (name, '');
    final q = s.codeUnitAt(_i);
    if (q == 0x22 || q == 0x27) {
      final end = s.indexOf(String.fromCharCode(q), _i + 1);
      final value = s.substring(_i + 1, end < 0 ? s.length : end);
      _i = end < 0 ? s.length : end + 1;
      return (name, value);
    }
    final valueStart = _i;
    while (_i < s.length &&
        !_isSpace(s.codeUnitAt(_i)) &&
        s.codeUnitAt(_i) != 0x3E) {
      _i++;
    }
    return (name, s.substring(valueStart, _i));
  }
}
