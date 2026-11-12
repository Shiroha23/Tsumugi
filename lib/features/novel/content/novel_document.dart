import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../../../sources/model/common.dart';
import '../../../sources/model/content.dart';

/// 小说章节的排版结构（docs/source-spec.md §2.2.1）。
///
/// 正文无论是纯文本还是受限 HTML，都先转换成这里的块序列，阅读器只渲染块，
/// 从不把源给出的 HTML 交给任何 HTML 渲染器。
sealed class NovelBlock {
  const NovelBlock();

  /// 参与“章节内字符偏移”计算的纯文本（§2.2.1 阅读位置）。
  String get plainText;

  int get length => plainText.length;
}

enum NovelParagraphKind {
  body,
  quote,
  heading1,
  heading2,
  heading3,
  heading4;

  bool get isHeading => index >= heading1.index;
}

/// 行内片段。[annotation] 为 true 时是 `rt` 注音，以小号字紧随基字显示。
final class NovelSpan {
  const NovelSpan(
    this.text, {
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strike = false,
    this.annotation = false,
  });

  final String text;
  final bool bold;
  final bool italic;
  final bool underline;
  final bool strike;
  final bool annotation;

  bool sameStyle(NovelSpan o) =>
      o.bold == bold &&
      o.italic == italic &&
      o.underline == underline &&
      o.strike == strike &&
      o.annotation == annotation;

  NovelSpan withText(String text) => NovelSpan(
    text,
    bold: bold,
    italic: italic,
    underline: underline,
    strike: strike,
    annotation: annotation,
  );

  @override
  bool operator ==(Object other) =>
      other is NovelSpan && other.text == text && sameStyle(other);

  @override
  int get hashCode =>
      Object.hash(text, bold, italic, underline, strike, annotation);

  @override
  String toString() {
    final flags = [
      if (bold) 'b',
      if (italic) 'i',
      if (underline) 'u',
      if (strike) 's',
      if (annotation) 'rt',
    ];
    return flags.isEmpty ? '"$text"' : '"$text"[${flags.join(',')}]';
  }
}

final class NovelParagraph extends NovelBlock {
  const NovelParagraph(this.spans, {this.kind = NovelParagraphKind.body});

  /// 纯文本段落。
  NovelParagraph.text(
    String text, {
    NovelParagraphKind kind = NovelParagraphKind.body,
  }) : this([NovelSpan(text)], kind: kind);

  final List<NovelSpan> spans;
  final NovelParagraphKind kind;

  @override
  String get plainText => spans.map((s) => s.text).join();

  /// 取 `[start, end)` 范围内的片段（按 [plainText] 的偏移）。
  List<NovelSpan> slice(int start, int end) {
    final out = <NovelSpan>[];
    var pos = 0;
    for (final s in spans) {
      final a = pos;
      final b = pos + s.text.length;
      pos = b;
      if (b <= start || a >= end) continue;
      out.add(
        s.withText(
          s.text.substring(
            (start - a).clamp(0, s.text.length),
            (end - a).clamp(0, s.text.length),
          ),
        ),
      );
    }
    return out;
  }

  @override
  bool operator ==(Object other) =>
      other is NovelParagraph &&
      other.kind == kind &&
      _listEquals(other.spans, spans);

  @override
  int get hashCode => Object.hash(kind, Object.hashAll(spans));

  @override
  String toString() => 'P(${kind.name}, $spans)';
}

final class NovelImage extends NovelBlock {
  const NovelImage(this.url, {this.alt});

  /// 已基于 baseUrl 解析的 http(s) 绝对地址。
  final String url;
  final String? alt;

  @override
  String get plainText => '￼';

  @override
  bool operator ==(Object other) =>
      other is NovelImage && other.url == url && other.alt == alt;

  @override
  int get hashCode => Object.hash(url, alt);

  @override
  String toString() => 'Img($url)';
}

final class NovelDivider extends NovelBlock {
  const NovelDivider();

  @override
  String get plainText => '―';

  @override
  bool operator ==(Object other) => other is NovelDivider;

  @override
  int get hashCode => 0;

  @override
  String toString() => 'Hr';
}

/// 一章的正文（可能由多次 `content` 的分页拼接而成）。
final class NovelChapter {
  NovelChapter(this.blocks, {this.imageHeaders}) {
    var offset = 0;
    for (final b in blocks) {
      _starts.add(offset);
      offset += b.length + 1;
    }
    length = blocks.isEmpty ? 0 : offset - 1;
  }

  final List<NovelBlock> blocks;

  /// 加载正文图片时携带的 headers（源清单的默认 headers）。
  final Headers? imageHeaders;
  final _starts = <int>[];

  /// 各块以 `\n` 连接后的总长度。
  late final int length;

  /// 第 [index] 块在章节纯文本中的起始偏移。
  int startOf(int index) => _starts[index];

  /// 偏移 [position] 所在的块与块内偏移；超出范围时取最近的一端。
  (int block, int offset) locate(int position) {
    if (blocks.isEmpty) return (0, 0);
    if (position <= 0) return (0, 0);
    var lo = 0;
    var hi = blocks.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_starts[mid] <= position) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return (lo, (position - _starts[lo]).clamp(0, blocks[lo].length));
  }

  String get plainText => blocks.map((b) => b.plainText).join('\n');
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

// -----------------------------------------------------------------------------
// 转换

/// 由 `content()` 的结果得到块序列。[baseUrl] 用于解析 HTML 中图片的相对地址。
List<NovelBlock> novelBlocksFromContent(
  NovelContent content, {
  String? baseUrl,
}) => content.html
    ? sanitizeNovelHtml(content.text, baseUrl: baseUrl)
    : novelBlocksFromText(content.text);

/// 段首 / 段尾要去掉的空白：普通空白、全角空格、不换行空格等。
final _edgeSpace = RegExp(r'^[\s　 ﻿]+|[\s　 ﻿]+$');

String _trimEdges(String s) => s.replaceAll(_edgeSpace, '');

/// 纯文本正文：按换行切段，去掉首尾空白，丢弃空段。
List<NovelBlock> novelBlocksFromText(String text) => [
  for (final line in text.split(RegExp(r'\r\n|\r|\n')))
    if (_trimEdges(line) case final t when t.isNotEmpty) NovelParagraph.text(t),
];

/// 整体丢弃（含内容）的标签。
const _dropped = {
  'script',
  'style',
  'template',
  'noscript',
  'iframe',
  'frame',
  'frameset',
  'object',
  'embed',
  'applet',
  'svg',
  'math',
  'canvas',
  'audio',
  'video',
  'source',
  'track',
  'head',
  'title',
  'meta',
  'link',
  'base',
  'form',
  'input',
  'button',
  'select',
  'option',
  'textarea',
  'rp',
};

/// 只保留文字、但视为段落边界的块级容器。
const _blockContainers = {
  'p',
  'div',
  'blockquote',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'section',
  'article',
  'main',
  'header',
  'footer',
  'aside',
  'nav',
  'ul',
  'ol',
  'li',
  'dl',
  'dt',
  'dd',
  'table',
  'thead',
  'tbody',
  'tfoot',
  'tr',
  'td',
  'th',
  'caption',
  'figure',
  'figcaption',
  'pre',
  'address',
  'center',
  'body',
  'html',
};

final _collapse = RegExp(r'[ \t\n\r\f]+');

/// 受限 HTML 正文的白名单清洗（§2.2.1）。永不抛出：无法识别的内容只保留文字。
List<NovelBlock> sanitizeNovelHtml(String html, {String? baseUrl}) {
  final fragment = html_parser.parseFragment(html);
  final base = baseUrl == null ? null : Uri.tryParse(baseUrl);
  return (_HtmlWalker(base)..walkChildren(fragment, const _Style())).finish();
}

final class _Style {
  const _Style({
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strike = false,
    this.annotation = false,
    this.kind = NovelParagraphKind.body,
  });

  final bool bold;
  final bool italic;
  final bool underline;
  final bool strike;
  final bool annotation;
  final NovelParagraphKind kind;

  _Style copyWith({
    bool? bold,
    bool? italic,
    bool? underline,
    bool? strike,
    bool? annotation,
    NovelParagraphKind? kind,
  }) => _Style(
    bold: bold ?? this.bold,
    italic: italic ?? this.italic,
    underline: underline ?? this.underline,
    strike: strike ?? this.strike,
    annotation: annotation ?? this.annotation,
    kind: kind ?? this.kind,
  );
}

class _HtmlWalker {
  _HtmlWalker(this.base);

  final Uri? base;
  final blocks = <NovelBlock>[];
  final _spans = <NovelSpan>[];
  NovelParagraphKind _kind = NovelParagraphKind.body;

  /// 防御极深的嵌套（解析器本身不限制深度）。
  static const _maxDepth = 256;
  int _depth = 0;

  void walkChildren(dom.Node node, _Style style) {
    if (_depth >= _maxDepth) return;
    _depth++;
    for (final child in node.nodes) {
      _walk(child, style);
    }
    _depth--;
  }

  void _walk(dom.Node node, _Style style) {
    switch (node) {
      case dom.Text(:final data):
        _addText(data, style);
      case dom.Element(:final localName):
        final tag = localName?.toLowerCase() ?? '';
        if (_dropped.contains(tag)) return;
        switch (tag) {
          case 'br':
            _endParagraph();
          case 'hr':
            _endParagraph();
            blocks.add(const NovelDivider());
          case 'img':
            _addImage(node);
          case 'b' || 'strong':
            walkChildren(node, style.copyWith(bold: true));
          case 'i' || 'em':
            walkChildren(node, style.copyWith(italic: true));
          case 'u':
            walkChildren(node, style.copyWith(underline: true));
          case 's' || 'del' || 'strike':
            walkChildren(node, style.copyWith(strike: true));
          case 'rt':
            walkChildren(node, style.copyWith(annotation: true));
          default:
            if (_blockContainers.contains(tag)) {
              final kind = switch (tag) {
                'h1' => NovelParagraphKind.heading1,
                'h2' => NovelParagraphKind.heading2,
                'h3' => NovelParagraphKind.heading3,
                'h4' => NovelParagraphKind.heading4,
                'blockquote' => NovelParagraphKind.quote,
                _ => style.kind,
              };
              _endParagraph();
              walkChildren(node, style.copyWith(kind: kind));
              _endParagraph();
            } else {
              // span、a、font、ruby 等：去掉标签保留文字。
              walkChildren(node, style);
            }
        }
      default:
        // 注释、doctype 等。
        break;
    }
  }

  void _addText(String raw, _Style style) {
    var text = raw.replaceAll(_collapse, ' ');
    if (text.isEmpty) return;
    if (_spans.isEmpty) {
      text = text.replaceFirst(RegExp(r'^[\s　 ﻿]+'), '');
      if (text.isEmpty) return;
      _kind = style.kind;
    }
    final span = NovelSpan(
      text,
      bold: style.bold,
      italic: style.italic,
      underline: style.underline,
      strike: style.strike,
      annotation: style.annotation,
    );
    if (_spans.isNotEmpty && _spans.last.sameStyle(span)) {
      final last = _spans.removeLast();
      _spans.add(last.withText(last.text + text));
    } else {
      _spans.add(span);
    }
  }

  void _addImage(dom.Element node) {
    final src = node.attributes['src']?.trim();
    if (src == null || src.isEmpty) return;
    final parsed = Uri.tryParse(src);
    if (parsed == null) return;
    final resolved = base?.resolveUri(parsed) ?? parsed;
    if (!resolved.isAbsolute ||
        (resolved.scheme != 'http' && resolved.scheme != 'https') ||
        resolved.host.isEmpty) {
      return;
    }
    _endParagraph();
    final alt = node.attributes['alt']?.trim();
    blocks.add(
      NovelImage(
        resolved.toString(),
        alt: alt == null || alt.isEmpty ? null : alt,
      ),
    );
  }

  void _endParagraph() {
    if (_spans.isEmpty) return;
    // 去掉段尾空白（可能跨多个片段）。
    while (_spans.isNotEmpty) {
      final last = _spans.removeLast();
      final t = last.text.replaceFirst(RegExp(r'[\s　 ﻿]+$'), '');
      if (t.isNotEmpty) {
        _spans.add(last.withText(t));
        break;
      }
    }
    if (_spans.isNotEmpty) {
      blocks.add(NovelParagraph(List.of(_spans), kind: _kind));
    }
    _spans.clear();
    _kind = NovelParagraphKind.body;
  }

  List<NovelBlock> finish() {
    _endParagraph();
    return blocks;
  }
}
