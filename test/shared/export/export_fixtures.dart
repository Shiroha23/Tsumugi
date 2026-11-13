import 'dart:io';

import 'package:tsumugi/shared/export/export_models.dart';
import 'package:tsumugi/shared/novel/novel_document.dart';

/// 写入器测试用的虚构作品：一章纯文本、一章受限 HTML（test/fixtures/novel/chapter_html.html）。
ExportBook sampleBook({
  ExportImage? cover,
  List<String> skipped = const [],
  bool withMeta = true,
}) {
  final html = File('test/fixtures/novel/chapter_html.html').readAsStringSync();
  return ExportBook(
    info: ExportBookInfo(
      sourceId: 'com.example.novel',
      itemId: '/novel/book/1',
      title: '青石巷的钟表匠 <测试> & "引号"',
      author: withMeta ? '虚构作者丁' : null,
      description: withMeta ? '老钟表匠修好了一只会倒着走的怀表。\n第二段简介。' : null,
      sourceName: 'Mock 小说',
      exportedAt: DateTime(2026, 11, 13, 8, 5, 9),
    ),
    chapters: [
      ExportedChapter(
        unitId: '/novel/book/1/chapter/1',
        title: '第一章 倒走的怀表',
        content: NovelChapter(
          novelBlocksFromText('青石巷尽头有一家很小的钟表铺。\n　　这天傍晚，客人送来一只怀表。'),
        ),
      ),
      ExportedChapter(
        unitId: '/novel/book/1/chapter/2',
        title: '第二章 灯塔',
        content: NovelChapter(
          sanitizeNovelHtml(
            '$html<h3>小节</h3><blockquote>引用<b>粗</b><i>斜</i>'
            '<u>线</u><s>删</s></blockquote><hr>'
            '<p>控制字符\u0001与 &lt;script&gt; 文本</p>',
            baseUrl: 'https://novel.example.com/book/1',
          ),
        ),
      ),
    ],
    skipped: skipped,
    cover: cover,
  );
}
