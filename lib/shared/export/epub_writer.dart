import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import '../novel/novel_document.dart';
import 'export_models.dart';

/// 章节 / 书名页 / 封面页 `body` 内允许出现的元素：docs/source-spec.md §2.2.1 的白名单。
/// 文档骨架（`html` / `head` / `title` / `link` / `body`）另计；目录页 nav.xhtml 由生成器写死，
/// 额外使用 `nav` / `ol` / `li` / `a`。
const epubBodyTags = {
  'p',
  'div',
  'h1',
  'h2',
  'h3',
  'h4',
  'blockquote',
  'br',
  'hr',
  'span',
  'em',
  'i',
  'strong',
  'b',
  'u',
  's',
  'del',
  'ruby',
  'rt',
  'rp',
  'img',
};

/// 生成 EPUB 3 文件（同时附带 EPUB 2 的 toc.ncx，兼容旧阅读器）。
///
/// 结构：`mimetype`（首个条目、不压缩）→ `META-INF/container.xml` → `OEBPS/content.opf`、
/// `nav.xhtml`、`toc.ncx`、`style.css`、可选的封面（`cover.xhtml` + 图片）、书名页 `title.xhtml`、
/// 每章一个 `chapter-NNNN.xhtml`。
///
/// 正文由 [NovelChapter] 的块重新生成，只使用 [epubBodyTags] 中的元素、不带任何属性
/// （`img` 除外，且正文图片目前不嵌入）。
// TODO(export): 正文图片目前以“［图片：alt］”占位，后续可经统一图片加载下载后嵌入。
Uint8List buildNovelEpub(ExportBook book) {
  final info = book.info;
  final lang = _language(info.language);
  final archive = Archive();

  // mimetype 必须是第一个条目且不压缩（OCF §4.3）。
  final mimetype = utf8.encode('application/epub+zip');
  archive
    ..add(ArchiveFile.noCompress('mimetype', mimetype.length, mimetype))
    ..add(ArchiveFile.string('META-INF/container.xml', _containerXml));

  final chapters = [
    for (final (i, c) in book.chapters.indexed)
      (id: 'c${_pad(i + 1)}', href: 'chapter-${_pad(i + 1)}.xhtml', chapter: c),
  ];
  final cover = book.cover;
  final coverHref = cover == null ? null : 'cover.${cover.extension}';

  void add(String name, String content) =>
      archive.add(ArchiveFile.string('OEBPS/$name', content));

  add('content.opf', _opf(book, lang, chapters, coverHref));
  add('nav.xhtml', _nav(info, lang, chapters));
  add('toc.ncx', _ncx(book, chapters));
  add('style.css', _css);
  if (cover != null && coverHref != null) {
    archive.add(ArchiveFile.bytes('OEBPS/$coverHref', cover.bytes));
    add(
      'cover.xhtml',
      _xhtml(
        lang: lang,
        title: '封面',
        body: '<div><img src="$coverHref" alt="${_attr(info.title)}"/></div>',
      ),
    );
  }
  add('title.xhtml', _titlePage(book, lang));
  for (final c in chapters) {
    add(c.href, _chapter(c.chapter, lang));
  }
  return ZipEncoder().encodeBytes(archive, modified: info.exportedAt);
}

// -----------------------------------------------------------------------------
// 各文件

const _containerXml = '''<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
''';

const _css = '''body { margin: 0 5%; line-height: 1.6; }
h1, h2, h3, h4 { text-align: center; line-height: 1.3; }
p { margin: 0.4em 0; text-indent: 2em; }
blockquote { margin: 0.6em 1.5em; }
hr { margin: 1em 20%; }
img { max-width: 100%; }
rt { font-size: 0.6em; }
''';

typedef _ChapterEntry = ({String id, String href, ExportedChapter chapter});

String _opf(
  ExportBook book,
  String lang,
  List<_ChapterEntry> chapters,
  String? coverHref,
) {
  final info = book.info;
  final cover = book.cover;
  final out = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln(
      '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" '
      'unique-identifier="book-id" xml:lang="$lang">',
    )
    ..writeln('  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">')
    ..writeln(
      '    <dc:identifier id="book-id">${epubIdentifier(info)}</dc:identifier>',
    )
    ..writeln('    <dc:title>${_text(info.title)}</dc:title>')
    ..writeln('    <dc:language>$lang</dc:language>');
  if (_nonEmpty(info.author) case final author?) {
    out.writeln('    <dc:creator>${_text(author)}</dc:creator>');
  }
  if (_nonEmpty(info.description) case final d?) {
    out.writeln('    <dc:description>${_text(d)}</dc:description>');
  }
  out
    ..writeln('    <dc:source>${_text(info.sourceName)}</dc:source>')
    ..writeln(
      '    <meta property="dcterms:modified">'
      '${_utcStamp(info.exportedAt)}</meta>',
    );
  if (cover != null) {
    out.writeln('    <meta name="cover" content="cover-image"/>');
  }
  out
    ..writeln('  </metadata>')
    ..writeln('  <manifest>')
    ..writeln(
      '    <item id="nav" href="nav.xhtml" '
      'media-type="application/xhtml+xml" properties="nav"/>',
    )
    ..writeln(
      '    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>',
    )
    ..writeln('    <item id="css" href="style.css" media-type="text/css"/>');
  if (cover != null && coverHref != null) {
    out
      ..writeln(
        '    <item id="cover-image" href="$coverHref" '
        'media-type="${cover.mediaType}" properties="cover-image"/>',
      )
      ..writeln(
        '    <item id="cover" href="cover.xhtml" '
        'media-type="application/xhtml+xml"/>',
      );
  }
  out.writeln(
    '    <item id="title-page" href="title.xhtml" '
    'media-type="application/xhtml+xml"/>',
  );
  for (final c in chapters) {
    out.writeln(
      '    <item id="${c.id}" href="${c.href}" '
      'media-type="application/xhtml+xml"/>',
    );
  }
  out
    ..writeln('  </manifest>')
    ..writeln('  <spine toc="ncx">');
  if (cover != null) out.writeln('    <itemref idref="cover"/>');
  out.writeln('    <itemref idref="title-page"/>');
  for (final c in chapters) {
    out.writeln('    <itemref idref="${c.id}"/>');
  }
  out
    ..writeln('  </spine>')
    ..writeln('</package>');
  return out.toString();
}

String _nav(ExportBookInfo info, String lang, List<_ChapterEntry> chapters) {
  final items = StringBuffer()
    ..writeln('<li><a href="title.xhtml">${_text(info.title)}</a></li>');
  for (final c in chapters) {
    items.writeln(
      '<li><a href="${c.href}">${_text(_title(c.chapter.title))}</a></li>',
    );
  }
  return _xhtml(
    lang: lang,
    title: '目录',
    body:
        '<nav epub:type="toc" id="toc">\n<h1>目录</h1>\n<ol>\n$items</ol>\n</nav>',
  );
}

String _ncx(ExportBook book, List<_ChapterEntry> chapters) {
  final info = book.info;
  final points = StringBuffer();
  var order = 1;
  void point(String href, String label) {
    points
      ..writeln('    <navPoint id="np-$order" playOrder="$order">')
      ..writeln('      <navLabel><text>${_text(label)}</text></navLabel>')
      ..writeln('      <content src="$href"/>')
      ..writeln('    </navPoint>');
    order++;
  }

  point('title.xhtml', info.title);
  for (final c in chapters) {
    point(c.href, _title(c.chapter.title));
  }
  return '''<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head>
    <meta name="dtb:uid" content="${epubIdentifier(info)}"/>
    <meta name="dtb:depth" content="1"/>
    <meta name="dtb:totalPageCount" content="0"/>
    <meta name="dtb:maxPageNumber" content="0"/>
  </head>
  <docTitle><text>${_text(info.title)}</text></docTitle>
  <navMap>
$points  </navMap>
</ncx>
''';
}

String _titlePage(ExportBook book, String lang) {
  final info = book.info;
  final body = StringBuffer()..writeln('<h1>${_text(info.title)}</h1>');
  if (_nonEmpty(info.author) case final author?) {
    body.writeln('<p>作者：${_text(author)}</p>');
  }
  body
    ..writeln('<p>来源：${_text(info.sourceName)}</p>')
    ..writeln('<p>导出时间：${_text(formatExportTime(info.exportedAt))}</p>');
  if (_nonEmpty(info.description) case final d?) {
    body.writeln('<hr/>');
    for (final p in novelBlocksFromText(d)) {
      body.writeln('<p>${_text(p.plainText)}</p>');
    }
  }
  if (book.skipped.isNotEmpty) {
    body
      ..writeln('<hr/>')
      ..writeln('<p>以下 ${book.skipped.length} 章导出失败，未包含在本书中：</p>');
    for (final t in book.skipped) {
      body.writeln('<p>${_text(t)}</p>');
    }
  }
  return _xhtml(lang: lang, title: info.title, body: body.toString());
}

String _chapter(ExportedChapter chapter, String lang) {
  final title = _title(chapter.title);
  final body = StringBuffer()..writeln('<h2>${_text(title)}</h2>');
  for (final block in chapter.content.blocks) {
    body.writeln(_block(block));
  }
  return _xhtml(lang: lang, title: title, body: body.toString());
}

String _block(NovelBlock block) => switch (block) {
  NovelParagraph(:final kind) => switch (kind) {
    NovelParagraphKind.body => '<p>${_spans(block.spans)}</p>',
    NovelParagraphKind.quote =>
      '<blockquote>${_spans(block.spans)}</blockquote>',
    NovelParagraphKind.heading1 => '<h1>${_spans(block.spans)}</h1>',
    NovelParagraphKind.heading2 => '<h2>${_spans(block.spans)}</h2>',
    NovelParagraphKind.heading3 => '<h3>${_spans(block.spans)}</h3>',
    NovelParagraphKind.heading4 => '<h4>${_spans(block.spans)}</h4>',
  },
  // 正文图片暂不嵌入（见 buildNovelEpub 的 TODO）。
  NovelImage(:final alt) =>
    '<p>${_text(alt == null ? '［图片］' : '［图片：$alt］')}</p>',
  NovelDivider() => '<hr/>',
};

/// 行内片段：粗 / 斜 / 下划线 / 删除线分别为 `b` / `i` / `u` / `s`。
/// 同一 `ruby` 分组（[NovelSpan.ruby]）的全部片段整体还原为一个 `<ruby>`：其中每段连续的基字后接
/// `<rp>（</rp><rt>注音</rt><rp>）</rp>`，基字或注音内的样式不会改变注音与基字的对应关系。
String _spans(List<NovelSpan> spans) {
  final out = StringBuffer();
  var i = 0;
  while (i < spans.length) {
    final group = spans[i].ruby;
    if (group == null) {
      final s = spans[i++];
      // 不在 ruby 中的注音（清洗器不会产生，保险起见）以括号文字输出。
      out.write(s.annotation ? '（${_styled(s)}）' : _styled(s));
      continue;
    }
    var j = i;
    while (j < spans.length && spans[j].ruby == group) {
      j++;
    }
    out.write(_ruby(spans.sublist(i, j)));
    i = j;
  }
  return out.toString();
}

String _ruby(List<NovelSpan> group) {
  final out = StringBuffer('<ruby>');
  var k = 0;
  while (k < group.length) {
    while (k < group.length && !group[k].annotation) {
      out.write(_styled(group[k++]));
    }
    if (k == group.length) break;
    final rt = StringBuffer();
    while (k < group.length && group[k].annotation) {
      rt.write(_styled(group[k++]));
    }
    out.write('<rp>（</rp><rt>$rt</rt><rp>）</rp>');
  }
  out.write('</ruby>');
  return out.toString();
}

String _styled(NovelSpan s) {
  var t = _text(s.text);
  if (s.strike) t = '<s>$t</s>';
  if (s.underline) t = '<u>$t</u>';
  if (s.italic) t = '<i>$t</i>';
  if (s.bold) t = '<b>$t</b>';
  return t;
}

String _xhtml({
  required String lang,
  required String title,
  required String body,
}) =>
    '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="$lang" lang="$lang">
<head>
<title>${_text(title)}</title>
<link rel="stylesheet" type="text/css" href="style.css"/>
</head>
<body>
$body</body>
</html>
''';

// -----------------------------------------------------------------------------
// 工具

/// 稳定的书籍标识：由 sourceId 与 itemId 派生的 UUID（v5 格式），同一作品重复导出得到同一标识。
String epubIdentifier(ExportBookInfo info) {
  final digest = sha1
      .convert(utf8.encode('tsumugi\u0000${info.sourceId}\u0000${info.itemId}'))
      .bytes
      .sublist(0, 16);
  digest[6] = (digest[6] & 0x0F) | 0x50;
  digest[8] = (digest[8] & 0x3F) | 0x80;
  final hex = digest.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return 'urn:uuid:${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

final _langTag = RegExp(r'^[A-Za-z]{2,8}(-[A-Za-z0-9]{1,8})*$');

String _language(String lang) => _langTag.hasMatch(lang) ? lang : 'zh';

String _pad(int n) => n.toString().padLeft(4, '0');

String _title(String t) {
  final s = t.trim();
  return s.isEmpty ? '无标题' : s;
}

String? _nonEmpty(String? s) {
  final t = s?.trim();
  return t == null || t.isEmpty ? null : t;
}

String _utcStamp(DateTime t) {
  final u = t.toUtc();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${u.year.toString().padLeft(4, '0')}-${two(u.month)}-${two(u.day)}'
      'T${two(u.hour)}:${two(u.minute)}:${two(u.second)}Z';
}

/// XML 1.0 不允许的字符（控制字符、U+FFFE / U+FFFF、孤立的代理项）。
final _invalidXml = RegExp(
  r'[\x00-\x08\x0B\x0C\x0E-\x1F￾￿]|'
  r'[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]',
);

/// 文本节点转义（并去掉 XML 不允许的字符）。
String _text(String s) => s
    .replaceAll(_invalidXml, '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

/// 属性值转义。
String _attr(String s) => _text(s).replaceAll('"', '&quot;');
