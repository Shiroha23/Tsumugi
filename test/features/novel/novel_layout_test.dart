import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/features/novel/content/novel_document.dart';
import 'package:tsumugi/features/novel/reader/novel_layout.dart';
import 'package:tsumugi/features/novel/reader/novel_reader_preferences.dart';

NovelChapter _chapter() => NovelChapter([
  for (var i = 0; i < 12; i++) NovelParagraph.text('第$i段${'字' * (20 + i * 7)}'),
  const NovelImage('https://img.example.com/1.png'),
  const NovelDivider(),
  NovelParagraph.text('末段。'),
]);

NovelTextStyles _styles({double fontSize = 16}) => NovelTextStyles(
  NovelReaderPreferences(fontSize: fontSize, lineHeight: 1.5),
);

/// 把各页的片段按顺序拼回每块的覆盖范围。
Map<int, List<(int, int)>> _coverage(List<NovelPage> pages) {
  final out = <int, List<(int, int)>>{};
  for (final p in pages) {
    for (final f in p.fragments) {
      (out[f.block] ??= []).add((f.start, f.end));
    }
  }
  return out;
}

void main() {
  test('分页覆盖全部文字，片段首尾相接；图片独占一页', () {
    final chapter = _chapter();
    final pages = paginateNovel(chapter, _styles(), const Size(300, 200));
    expect(pages.length, greaterThan(3));

    final coverage = _coverage(pages);
    for (final (i, block) in chapter.blocks.indexed) {
      final ranges = coverage[i]!;
      expect(ranges.first.$1, 0, reason: 'block $i');
      expect(ranges.last.$2, block.length, reason: 'block $i');
      for (var k = 1; k < ranges.length; k++) {
        expect(ranges[k].$1, ranges[k - 1].$2, reason: 'block $i');
      }
    }
    final imagePage = pages.singleWhere(
      (p) => p.fragments.any((f) => f.block == 12),
    );
    expect(imagePage.fragments, hasLength(1));

    // 页起始偏移递增，并与首个片段一致。
    for (var k = 1; k < pages.length; k++) {
      expect(pages[k].start, greaterThan(pages[k - 1].start));
    }
    final f = pages[1].fragments.first;
    expect(pages[1].start, chapter.startOf(f.block) + f.start);
  });

  test('每页内容不超过可用高度', () {
    final chapter = _chapter();
    final styles = _styles();
    const size = Size(300, 200);
    for (final page in paginateNovel(chapter, styles, size)) {
      var h = 0.0;
      for (final (k, f) in page.fragments.indexed) {
        if (k > 0) h += styles.paragraphGap;
        final block = chapter.blocks[f.block];
        if (block is NovelParagraph) {
          final painter = styles.painter(
            styles.paragraph(block, f.start, f.end),
            size.width,
          );
          h += painter.height;
          painter.dispose();
        } else if (block is NovelDivider) {
          h += styles.dividerExtent;
        }
      }
      if (page.fragments.first.block != 12) {
        expect(h, lessThanOrEqualTo(size.height + 0.5));
      }
    }
  });

  test('字号变大则页数变多；novelPageOf 按偏移找页', () {
    final chapter = _chapter();
    const size = Size(300, 200);
    final small = paginateNovel(chapter, _styles(), size);
    final large = paginateNovel(chapter, _styles(fontSize: 28), size);
    expect(large.length, greaterThan(small.length));

    expect(novelPageOf(small, 0), 0);
    expect(novelPageOf(small, chapter.length), small.length - 1);
    final mid = small[2].start;
    expect(novelPageOf(small, mid), 2);
    expect(novelPageOf(small, mid + 1), 2);
    expect(novelPageOf(small, mid - 1), 1);
  });

  test('放不下一行时仍然前进（每页至少一行）', () {
    final pages = paginateNovel(
      NovelChapter([NovelParagraph.text('字' * 50)]),
      _styles(fontSize: 40),
      const Size(200, 10),
    );
    expect(pages, isNotEmpty);
    expect(_coverage(pages)[0]!.last.$2, 50);
  });

  test('段首缩进只加在段落第一个片段上，标题不缩进', () {
    final styles = _styles();
    final body = NovelParagraph.text('正文');
    final heading = NovelParagraph.text(
      '标题',
      kind: NovelParagraphKind.heading1,
    );
    expect(styles.paragraph(body).toPlainText(), '$novelIndent正文');
    expect(styles.paragraph(body, 1).toPlainText(), '文');
    expect(styles.paragraph(heading).toPlainText(), '标题');
  });
}
