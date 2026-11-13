import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/shared/export/epub_writer.dart';
import 'package:tsumugi/shared/export/export_models.dart';
import 'package:tsumugi/shared/novel/novel_document.dart';
import 'package:xml/xml.dart';

import 'export_fixtures.dart';

/// 1×1 透明 PNG（虚构封面）。
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
);

int _u16(Uint8List b, int o) => b[o] | (b[o + 1] << 8);
int _u32(Uint8List b, int o) => _u16(b, o) | (_u16(b, o + 2) << 16);

const _xhtmlNs = 'http://www.w3.org/1999/xhtml';
const _opfNs = 'http://www.idpf.org/2007/opf';

String _entry(Archive a, String name) =>
    utf8.decode(a.findFile(name)!.content as List<int>);

void main() {
  late Uint8List bytes;
  late Archive archive;

  setUp(() {
    bytes = buildNovelEpub(
      sampleBook(cover: ExportImage.sniff(_png), skipped: ['第三章 雨季']),
    );
    archive = ZipDecoder().decodeBytes(bytes);
  });

  test('mimetype 是首个条目、不压缩、无扩展字段', () {
    // 本地文件头（ZIP APPNOTE 4.3.7）。
    expect(_u32(bytes, 0), 0x04034b50);
    expect(_u16(bytes, 8), 0, reason: '压缩方式应为 stored');
    final nameLength = _u16(bytes, 26);
    expect(_u16(bytes, 28), 0, reason: '不应有扩展字段');
    expect(ascii.decode(bytes.sublist(30, 30 + nameLength)), 'mimetype');
    expect(
      ascii.decode(bytes.sublist(30 + nameLength, 30 + nameLength + 20)),
      'application/epub+zip',
    );
    expect(archive.files.first.name, 'mimetype');
  });

  test('container.xml 指向 OPF；OPF 的 manifest / spine 与文件、nav 一致', () {
    final container = XmlDocument.parse(
      _entry(archive, 'META-INF/container.xml'),
    );
    final rootfile = container.findAllElements('rootfile').single;
    expect(rootfile.getAttribute('full-path'), 'OEBPS/content.opf');
    expect(
      rootfile.getAttribute('media-type'),
      'application/oebps-package+xml',
    );

    final opf = XmlDocument.parse(_entry(archive, 'OEBPS/content.opf'));
    final package = opf.rootElement;
    expect(package.getAttribute('version'), '3.0');
    final uidRef = package.getAttribute('unique-identifier');
    final identifier = opf
        .findAllElements('dc:identifier')
        .singleWhere((e) => e.getAttribute('id') == uidRef);
    expect(identifier.innerText, startsWith('urn:uuid:'));
    expect(
      opf.findAllElements('dc:title').single.innerText,
      '青石巷的钟表匠 <测试> & "引号"',
    );
    expect(opf.findAllElements('dc:language').single.innerText, 'zh');
    expect(opf.findAllElements('dc:creator').single.innerText, '虚构作者丁');
    final modified = opf
        .findAllElements('meta', namespaceUri: _opfNs)
        .singleWhere((e) => e.getAttribute('property') == 'dcterms:modified');
    expect(
      modified.innerText,
      matches(RegExp(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$')),
    );

    final items = {
      for (final i in opf.findAllElements('item', namespaceUri: _opfNs))
        i.getAttribute('id')!: i,
    };
    // 每个 manifest 条目都对应 zip 中的文件，反之 OEBPS 下的每个文件都在 manifest 中。
    final hrefs = {for (final i in items.values) i.getAttribute('href')!};
    for (final h in hrefs) {
      expect(archive.findFile('OEBPS/$h'), isNotNull, reason: h);
    }
    final files = {
      for (final f in archive.files)
        if (f.name.startsWith('OEBPS/') && f.name != 'OEBPS/content.opf')
          f.name.substring('OEBPS/'.length),
    };
    expect(files, hrefs);
    expect(
      items.values.where((i) => i.getAttribute('properties') == 'nav'),
      hasLength(1),
    );
    final coverImage = items['cover-image']!;
    expect(coverImage.getAttribute('properties'), 'cover-image');
    expect(coverImage.getAttribute('media-type'), 'image/png');
    expect(archive.findFile('OEBPS/cover.png')!.content, _png);

    final spine = opf
        .findAllElements('itemref', namespaceUri: _opfNs)
        .map((e) => e.getAttribute('idref')!);
    expect(spine, ['cover', 'title-page', 'c0001', 'c0002']);
    for (final id in spine) {
      expect(items[id]?.getAttribute('media-type'), 'application/xhtml+xml');
    }

    // nav 中的链接都指向 spine 中的文档，顺序一致。
    final nav = XmlDocument.parse(_entry(archive, 'OEBPS/nav.xhtml'));
    final navEl = nav.findAllElements('nav', namespaceUri: _xhtmlNs).single;
    expect(
      navEl.getAttribute('type', namespaceUri: 'http://www.idpf.org/2007/ops'),
      'toc',
    );
    final links = [
      for (final a in navEl.findAllElements('a', namespaceUri: _xhtmlNs))
        (a.getAttribute('href')!, a.innerText),
    ];
    expect(links, [
      ('title.xhtml', '青石巷的钟表匠 <测试> & "引号"'),
      ('chapter-0001.xhtml', '第一章 倒走的怀表'),
      ('chapter-0002.xhtml', '第二章 灯塔'),
    ]);
    final spineHrefs = [
      for (final id in spine) items[id]!.getAttribute('href'),
    ];
    for (final (href, _) in links) {
      expect(spineHrefs, contains(href));
    }

    // toc.ncx 与 nav 一致。
    final ncx = XmlDocument.parse(_entry(archive, 'OEBPS/toc.ncx'));
    expect(
      ncx.findAllElements('content').map((e) => e.getAttribute('src')),
      links.map((l) => l.$1),
    );
    expect(
      ncx
          .findAllElements('meta')
          .singleWhere((e) => e.getAttribute('name') == 'dtb:uid')
          .getAttribute('content'),
      identifier.innerText,
    );
  });

  test('每个 XHTML 都是合法 XML，body 内只有 §2.2.1 白名单标签、无多余属性', () {
    final docs = archive.files.where(
      (f) => f.name.endsWith('.xhtml') && f.name != 'OEBPS/nav.xhtml',
    );
    expect(docs, hasLength(4));
    for (final f in docs) {
      final doc = XmlDocument.parse(utf8.decode(f.content as List<int>));
      final html = doc.rootElement;
      expect(html.name.local, 'html');
      expect(html.namespaceUri, _xhtmlNs);
      final body = html.findElements('body', namespaceUri: _xhtmlNs).single;
      for (final e in body.descendantElements) {
        expect(epubBodyTags, contains(e.name.local), reason: '${f.name}: $e');
        final attrs = {for (final a in e.attributes) a.name.local};
        if (e.name.local == 'img') {
          expect(attrs.difference({'src', 'alt'}), isEmpty);
        } else {
          expect(attrs, isEmpty, reason: '${f.name}: $e');
        }
      }
    }
  });

  test('正文：段落、标题、引用、行内样式、ruby、分隔线；脚本与控制字符不出现', () {
    final c2 = _entry(archive, 'OEBPS/chapter-0002.xhtml');
    final body = XmlDocument.parse(c2)
        .findAllElements('body', namespaceUri: _xhtmlNs)
        .single;
    final tops = [for (final e in body.childElements) e.name.local];
    expect(tops, ['h2', 'p', 'p', 'p', 'p', 'h3', 'blockquote', 'hr', 'p']);
    expect(body.childElements.first.innerText, '第二章 灯塔');
    expect(c2, contains('<p>灯塔守夜人在日志里写下：<i>今晚无风</i>。</p>'));
    expect(c2, contains('<p>［图片：灯塔］</p>'));
    expect(
      c2,
      contains(
        '<p>他把<ruby>灯芯<rp>（</rp><rt>とうしん</rt><rp>）</rp></ruby>剪短了一些。</p>',
      ),
    );
    expect(
      c2,
      contains('<blockquote>引用<b>粗</b><i>斜</i><u>线</u><s>删</s></blockquote>'),
    );
    expect(c2, contains('<p>控制字符与 &lt;script&gt; 文本</p>'));
    expect(c2, isNot(contains('tracker')));
    expect(c2, isNot(contains('onload')));
  });

  test('ruby 分组完整保留：基字 / 注音内的样式不改变对应关系，相邻 ruby 各自成组', () {
    final book = ExportBook(
      info: sampleBook().info,
      chapters: [
        ExportedChapter(
          unitId: 'r',
          title: 'ruby',
          content: NovelChapter(
            sanitizeNovelHtml(
              '<p><ruby><b>漢</b>字<rt>かん<i>じ</i></rt></ruby>'
              '<ruby>灯<rt>ひ</rt></ruby>'
              '<ruby>甲<rt>こう</rt>乙<rt>おつ</rt></ruby></p>',
            ),
          ),
        ),
      ],
    );
    final a = ZipDecoder().decodeBytes(buildNovelEpub(book));
    final c = _entry(a, 'OEBPS/chapter-0001.xhtml');
    expect(
      c,
      contains(
        '<p><ruby><b>漢</b>字<rp>（</rp><rt>かん<i>じ</i></rt><rp>）</rp></ruby>'
        '<ruby>灯<rp>（</rp><rt>ひ</rt><rp>）</rp></ruby>'
        '<ruby>甲<rp>（</rp><rt>こう</rt><rp>）</rp>'
        '乙<rp>（</rp><rt>おつ</rt><rp>）</rp></ruby></p>',
      ),
    );
    XmlDocument.parse(c);
  });

  test('书名页列出元数据与跳过的章节；封面图片识别失败时不放封面', () {
    final title = _entry(archive, 'OEBPS/title.xhtml');
    expect(title, contains('<p>来源：Mock 小说</p>'));
    expect(title, contains('<p>导出时间：2026-11-13 08:05</p>'));
    expect(title, contains('<p>第三章 雨季</p>'));

    final noCover = ZipDecoder().decodeBytes(
      buildNovelEpub(
        sampleBook(cover: ExportImage.sniff(Uint8List.fromList([1, 2, 3]))),
      ),
    );
    expect(noCover.findFile('OEBPS/cover.xhtml'), isNull);
    expect(_entry(noCover, 'OEBPS/content.opf'), isNot(contains('cover')));
  });

  test('同一作品的标识稳定，不同作品不同', () {
    final a = sampleBook().info;
    expect(epubIdentifier(a), epubIdentifier(sampleBook().info));
    final other = ExportBookInfo(
      sourceId: a.sourceId,
      itemId: '/novel/book/2',
      title: a.title,
      sourceName: a.sourceName,
      exportedAt: a.exportedAt,
    );
    expect(epubIdentifier(other), isNot(epubIdentifier(a)));
    expect(
      epubIdentifier(a),
      matches(
        RegExp(
          r'^urn:uuid:[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ),
      ),
    );
  });
}
