import 'dart:math' as math;

import 'package:flutter/painting.dart';

import '../content/novel_document.dart';
import 'novel_reader_preferences.dart';

/// 段首缩进（两个全角空格）。正文与引用段落的第一个片段带缩进，标题不缩进。
const novelIndent = '　　';

/// 由偏好得到的正文样式。阅读器的渲染与分页都只通过这里构造文字，保证二者一致。
final class NovelTextStyles {
  NovelTextStyles(this.prefs, {this.textScaler = TextScaler.noScaling});

  final NovelReaderPreferences prefs;
  final TextScaler textScaler;

  late final TextStyle body = TextStyle(
    fontSize: prefs.fontSize,
    height: prefs.lineHeight,
    color: prefs.theme.foreground,
    fontFamily: prefs.font.families?.first,
    fontFamilyFallback: prefs.font.families,
    leadingDistribution: TextLeadingDistribution.even,
  );

  late final TextStyle quote = body.copyWith(color: prefs.theme.muted);

  TextStyle heading(NovelParagraphKind kind) => body.copyWith(
    fontSize:
        prefs.fontSize *
        switch (kind) {
          NovelParagraphKind.heading1 => 1.5,
          NovelParagraphKind.heading2 => 1.35,
          NovelParagraphKind.heading3 => 1.2,
          _ => 1.1,
        },
    fontWeight: FontWeight.bold,
  );

  /// 章节标题（滚动模式的正文开头）。
  late final TextStyle chapterTitle = heading(NovelParagraphKind.heading2);

  /// 段落间距。
  double get paragraphGap => prefs.fontSize * prefs.paragraphSpacing;

  /// 分隔线占用的高度（一行）。
  double get dividerExtent =>
      textScaler.scale(prefs.fontSize) * prefs.lineHeight;

  /// 页边距：左右为 [NovelReaderPreferences.margin]，上下略小。
  EdgeInsets get padding => EdgeInsets.symmetric(
    horizontal: prefs.margin,
    vertical: math.max(8, prefs.margin * 0.6),
  );

  TextStyle styleOf(NovelParagraphKind kind) => switch (kind) {
    NovelParagraphKind.body => body,
    NovelParagraphKind.quote => quote,
    _ => heading(kind),
  };

  static bool indents(NovelParagraphKind kind) => !kind.isHeading;

  /// 片段 `[start, end)` 是否带缩进。
  static bool indented(NovelParagraph p, int start) =>
      start == 0 && indents(p.kind);

  /// 段落 [p] 的 `[start, end)` 部分（[end] 省略时到段尾）。
  TextSpan paragraph(NovelParagraph p, [int start = 0, int? end]) {
    final base = styleOf(p.kind);
    return TextSpan(
      style: base,
      children: [
        if (indented(p, start)) const TextSpan(text: novelIndent),
        for (final s in p.slice(start, end ?? p.length))
          TextSpan(text: s.text, style: _inline(s, base)),
      ],
    );
  }

  TextStyle? _inline(NovelSpan s, TextStyle base) {
    if (!s.bold && !s.italic && !s.underline && !s.strike && !s.annotation) {
      return null;
    }
    final decorations = [
      if (s.underline) TextDecoration.underline,
      if (s.strike) TextDecoration.lineThrough,
    ];
    return TextStyle(
      fontWeight: s.bold ? FontWeight.bold : null,
      fontStyle: s.italic ? FontStyle.italic : null,
      decoration: decorations.isEmpty
          ? null
          : TextDecoration.combine(decorations),
      fontSize: s.annotation ? (base.fontSize ?? 16) * 0.6 : null,
      color: s.annotation ? prefs.theme.muted : null,
    );
  }

  TextPainter painter(InlineSpan span, double width) => TextPainter(
    text: span,
    textDirection: TextDirection.ltr,
    textScaler: textScaler,
  )..layout(maxWidth: width);
}

/// 一页上的一段内容：第 [block] 块的 `[start, end)`（图片 / 分隔线为 `[0, 1)`）。
final class NovelFragment {
  const NovelFragment(this.block, this.start, this.end);

  final int block;
  final int start;
  final int end;

  @override
  bool operator ==(Object other) =>
      other is NovelFragment &&
      other.block == block &&
      other.start == start &&
      other.end == end;

  @override
  int get hashCode => Object.hash(block, start, end);

  @override
  String toString() => 'F($block, $start-$end)';
}

final class NovelPage {
  const NovelPage(this.fragments, this.start);

  final List<NovelFragment> fragments;

  /// 本页第一个字符在章节中的偏移。
  final int start;
}

/// 把 [chapter] 按 [size]（正文区域，已扣除页边距）分页。
///
/// 段落按行切分：能放下的行留在本页，其余移到下一页；图片独占一页；段落之间留 [NovelTextStyles.paragraphGap]。
/// 每页至少放一行，因此字号大到放不下一行时也不会死循环。
List<NovelPage> paginateNovel(
  NovelChapter chapter,
  NovelTextStyles styles,
  Size size,
) {
  final width = math.max(1.0, size.width);
  final height = math.max(1.0, size.height);
  const epsilon = 0.5;
  final pages = <NovelPage>[];
  var current = <NovelFragment>[];
  var y = 0.0;

  void push() {
    if (current.isEmpty) return;
    final f = current.first;
    pages.add(NovelPage(current, chapter.startOf(f.block) + f.start));
    current = [];
    y = 0;
  }

  for (final (i, block) in chapter.blocks.indexed) {
    switch (block) {
      case NovelImage():
        push();
        current.add(NovelFragment(i, 0, 1));
        push();
      case NovelDivider():
        final gap = current.isEmpty ? 0.0 : styles.paragraphGap;
        final h = styles.dividerExtent;
        if (current.isNotEmpty && y + gap + h > height + epsilon) push();
        y += (current.isEmpty ? 0 : gap) + h;
        current.add(NovelFragment(i, 0, 1));
      case NovelParagraph():
        final painter = styles.painter(styles.paragraph(block), width);
        final lines = painter.computeLineMetrics();
        final indent = NovelTextStyles.indented(block, 0)
            ? novelIndent.length
            : 0;
        int lineStart(int k) {
          if (k <= 0) return 0;
          if (k >= lines.length) return block.length;
          final l = lines[k];
          final pos = painter.getPositionForOffset(
            Offset(0, l.baseline - l.ascent + l.height / 2),
          );
          final start = painter.getLineBoundary(pos).start;
          return (start - indent).clamp(0, block.length);
        }

        var k = 0;
        while (k < lines.length) {
          final gap = current.isEmpty || k > 0 ? 0.0 : styles.paragraphGap;
          var used = gap;
          var end = k;
          while (end < lines.length &&
              y + used + lines[end].height <= height + epsilon) {
            used += lines[end].height;
            end++;
          }
          if (end == k) {
            if (current.isNotEmpty) {
              push();
              continue;
            }
            // 空页仍放不下一行：强制放一行。
            used = lines[k].height;
            end = k + 1;
          }
          current.add(NovelFragment(i, lineStart(k), lineStart(end)));
          y += used;
          k = end;
          if (k < lines.length) push();
        }
        painter.dispose();
    }
  }
  push();
  return pages;
}

/// [position] 所在的页（最后一个起始偏移不大于它的页）。
int novelPageOf(List<NovelPage> pages, int position) {
  if (pages.isEmpty) return 0;
  var lo = 0;
  var hi = pages.length - 1;
  while (lo < hi) {
    final mid = (lo + hi + 1) >> 1;
    if (pages[mid].start <= position) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  return lo;
}
