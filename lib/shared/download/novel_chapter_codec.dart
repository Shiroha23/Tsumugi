import 'dart:convert';

import '../novel/novel_document.dart';

/// `chapter.json`：清洗后的 [NovelChapter] 的序列化结果（docs/architecture.md §4.5）。
///
/// 只保存块结构（段落 / 图片 / 分隔线）与文字样式，读取时按结构严格反序列化，
/// 不经过任何 HTML 解析或渲染；图片保留原地址，本地文件由 `unit.json` 的映射给出。
/// 任何字段不符都抛出 [FormatException]（视为损坏，阅读器回退到网络）。
abstract final class NovelChapterCodec {
  static const version = 1;

  static String encode(NovelChapter chapter) => jsonEncode({
    'version': version,
    'imageHeaders': ?chapter.imageHeaders,
    'blocks': [for (final b in chapter.blocks) _block(b)],
  });

  static Map<String, Object?> _block(NovelBlock b) => switch (b) {
    NovelParagraph(:final spans, :final kind) => {
      't': 'p',
      'k': kind.name,
      's': [for (final s in spans) _span(s)],
    },
    NovelImage(:final url, :final alt) => {'t': 'img', 'url': url, 'alt': ?alt},
    NovelDivider() => {'t': 'hr'},
  };

  static Map<String, Object?> _span(NovelSpan s) => {
    'x': s.text,
    if (s.bold) 'b': true,
    if (s.italic) 'i': true,
    if (s.underline) 'u': true,
    if (s.strike) 's': true,
    if (s.annotation) 'rt': true,
    'r': ?s.ruby,
  };

  static NovelChapter decode(String text) {
    final json = jsonDecode(text);
    if (json is! Map || json['version'] != version) {
      throw const FormatException('chapter.json: 版本不符');
    }
    Map<String, String>? headers;
    if (json['imageHeaders'] case final Map raw) {
      headers = {};
      for (final MapEntry(:key, :value) in raw.entries) {
        if (key is! String || value is! String) {
          throw const FormatException('chapter.json: headers');
        }
        headers[key] = value;
      }
    } else if (json['imageHeaders'] != null) {
      throw const FormatException('chapter.json: headers');
    }
    final blocks = json['blocks'];
    if (blocks is! List) throw const FormatException('chapter.json: blocks');
    return NovelChapter([
      for (final b in blocks) _decodeBlock(b),
    ], imageHeaders: headers);
  }

  static final _kinds = {for (final k in NovelParagraphKind.values) k.name: k};

  static NovelBlock _decodeBlock(Object? b) {
    if (b is! Map) throw const FormatException('chapter.json: block');
    switch (b['t']) {
      case 'p':
        final kind = _kinds[b['k']];
        final spans = b['s'];
        if (kind == null || spans is! List) {
          throw const FormatException('chapter.json: paragraph');
        }
        return NovelParagraph([
          for (final s in spans) _decodeSpan(s),
        ], kind: kind);
      case 'img':
        final url = b['url'];
        final alt = b['alt'];
        if (url is! String || (alt != null && alt is! String)) {
          throw const FormatException('chapter.json: image');
        }
        final uri = Uri.tryParse(url);
        if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
          throw const FormatException('chapter.json: image url');
        }
        return NovelImage(url, alt: alt as String?);
      case 'hr':
        return const NovelDivider();
      default:
        throw const FormatException('chapter.json: block type');
    }
  }

  static NovelSpan _decodeSpan(Object? s) {
    if (s is! Map) throw const FormatException('chapter.json: span');
    final text = s['x'];
    final ruby = s['r'];
    if (text is! String || (ruby != null && ruby is! int)) {
      throw const FormatException('chapter.json: span');
    }
    bool flag(String k) => switch (s[k]) {
      null => false,
      true => true,
      _ => throw const FormatException('chapter.json: span flag'),
    };
    return NovelSpan(
      text,
      bold: flag('b'),
      italic: flag('i'),
      underline: flag('u'),
      strike: flag('s'),
      annotation: flag('rt'),
      ruby: ruby as int?,
    );
  }
}
