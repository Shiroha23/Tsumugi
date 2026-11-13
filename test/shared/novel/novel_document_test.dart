import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/shared/novel/novel_document.dart';
import 'package:tsumugi/sources/model/content.dart';

const _base = 'https://novel.example.com/book/1/';

List<NovelBlock> _html(String s) => sanitizeNovelHtml(s, baseUrl: _base);

String _texts(List<NovelBlock> blocks) =>
    blocks.map((b) => b.plainText).join('|');

void main() {
  group('纯文本', () {
    test('按换行切段，去掉首尾全角 / 不换行空格，丢弃空段', () {
      final blocks = novelBlocksFromText('　　第一段。\r\n\n  第二段  \n　\n第三段');
      expect(blocks, [
        NovelParagraph.text('第一段。'),
        NovelParagraph.text('第二段'),
        NovelParagraph.text('第三段'),
      ]);
    });

    test('html=false 时尖括号原样保留为文字', () {
      final blocks = novelBlocksFromContent(
        const NovelContent(text: '<b>不是标签</b>'),
      );
      expect(blocks, [NovelParagraph.text('<b>不是标签</b>')]);
    });
  });

  group('受限 HTML', () {
    test('段落、br 换段、标题、引用、分隔线', () {
      final blocks = _html(
        '<h2>第一章</h2><p>　　甲。</p>乙<br>丙<br/><br>'
        '<blockquote>引文</blockquote><hr><div>丁</div>',
      );
      expect(blocks, [
        NovelParagraph.text('第一章', kind: NovelParagraphKind.heading2),
        NovelParagraph.text('甲。'),
        NovelParagraph.text('乙'),
        NovelParagraph.text('丙'),
        NovelParagraph.text('引文', kind: NovelParagraphKind.quote),
        const NovelDivider(),
        NovelParagraph.text('丁'),
      ]);
    });

    test('行内样式与 ruby（rp 丢弃）', () {
      final blocks = _html(
        '<p>一<b>粗</b><strong>体</strong><em>斜</em><u>下</u><del>删</del>'
        '<ruby>漢<rp>(</rp><rt>かん</rt><rp>)</rp></ruby>。</p>',
      );
      expect(blocks, hasLength(1));
      final p = blocks.single as NovelParagraph;
      expect(p.spans, const [
        NovelSpan('一'),
        NovelSpan('粗体', bold: true),
        NovelSpan('斜', italic: true),
        NovelSpan('下', underline: true),
        NovelSpan('删', strike: true),
        NovelSpan('漢', ruby: 0),
        NovelSpan('かん', annotation: true, ruby: 0),
        NovelSpan('。'),
      ]);
      expect(p.plainText, '一粗体斜下删漢かん。');
    });

    test('空白折叠、实体解码', () {
      expect(_html('<p>  a \n\t b&nbsp;&amp;&lt;c&gt; </p>'), [
        NovelParagraph.text('a b &<c>'),
      ]);
    });

    test('图片：解析相对地址，独立成块并拆开段落', () {
      final blocks = _html(
        '<p>前<img src="../img/1.png" alt="插图" onerror="x()">后</p>'
        '<img src="//cdn.example.com/2.jpg">',
      );
      expect(blocks, [
        NovelParagraph.text('前'),
        const NovelImage('https://novel.example.com/book/img/1.png', alt: '插图'),
        NovelParagraph.text('后'),
        const NovelImage('https://cdn.example.com/2.jpg'),
      ]);
    });

    test('未知标签去掉标签保留文字；列表 / 表格按段落边界', () {
      expect(
        _texts(
          _html(
            '<p><a href="/x">链接</a><font color="red">字</font></p>'
            '<ul><li>一</li><li>二</li></ul><table><tr><td>格</td></tr></table>',
          ),
        ),
        '链接字|一|二|格',
      );
    });

    test('恶意输入：脚本、事件、样式、危险协议与嵌入内容全部去除', () {
      final blocks = _html('''
<script>alert(1)</script>
<p onclick="steal()" style="background:url(javascript:alert(2))">正文<span onmouseover="x()">一</span></p>
<img src="javascript:alert(3)"><img src="data:image/png;base64,AAAA"><img src="vbscript:x">
<img src=" "><img>
<iframe src="https://evil.example.com/"><p>框内</p></iframe>
<svg><script>alert(4)</script><text>svg 文字</text></svg>
<math><mi>x</mi></math>
<style>p { display: none }</style>
<object data="x.swf">对象</object><embed src="x">
<template><p>模板</p></template>
<noscript>无脚本</noscript>
<form action="https://evil.example.com/"><input value="v"><textarea>文本框</textarea><button>按钮</button></form>
<!-- 注释 -->
<a href="javascript:alert(5)">链接文字</a>
<p>结尾</p>''');
      expect(_texts(blocks), '正文一|链接文字|结尾');
      for (final b in blocks) {
        expect(b, isNot(isA<NovelImage>()));
        expect(b.plainText, isNot(contains('alert')));
      }
    });

    test('未闭合 / 错误嵌套 / 大小写混用的标签不会出错', () {
      expect(
        _texts(_html('<P>甲<B>乙<I>丙</P>丁<ScRiPt>bad()</sCrIpT><div><p>戊')),
        '甲乙丙|丁|戊',
      );
    });

    test('极深嵌套不会栈溢出', () {
      final deep = '${'<span>' * 5000}深${'</span>' * 5000}';
      expect(() => _html(deep), returnsNormally);
    });

    test('没有 baseUrl 时相对图片被丢弃', () {
      expect(sanitizeNovelHtml('<img src="/a.png">'), isEmpty);
    });

    test('fixture：混合内容', () {
      final html = File('test/fixtures/novel/chapter_html.html')
          .readAsStringSync();
      final blocks = _html(html);
      expect(blocks.whereType<NovelImage>().map((i) => i.url), [
        'https://novel.example.com/img/lamp.png',
      ]);
      expect(_texts(blocks), isNot(contains('tracker')));
      expect(blocks.first, isA<NovelParagraph>());
    });
  });

  group('NovelChapter', () {
    test('偏移按块以换行连接计算；locate 定位块与块内偏移', () {
      final chapter = NovelChapter([
        NovelParagraph.text('abc'),
        const NovelImage('https://a.example.com/1.png'),
        NovelParagraph.text('de'),
      ]);
      expect(chapter.plainText, 'abc\n￼\nde');
      expect(chapter.length, 8);
      expect(chapter.startOf(1), 4);
      expect(chapter.startOf(2), 6);
      expect(chapter.locate(0), (0, 0));
      expect(chapter.locate(2), (0, 2));
      expect(chapter.locate(3), (0, 3));
      expect(chapter.locate(4), (1, 0));
      expect(chapter.locate(7), (2, 1));
      expect(chapter.locate(99), (2, 2));
      expect(NovelChapter(const []).locate(5), (0, 0));
    });

    test('段落切片保留样式', () {
      const p = NovelParagraph([
        NovelSpan('ab'),
        NovelSpan('cd', bold: true),
        NovelSpan('ef'),
      ]);
      expect(p.slice(1, 5), const [
        NovelSpan('b'),
        NovelSpan('cd', bold: true),
        NovelSpan('e'),
      ]);
    });
  });
}
