import 'dart:convert';
import 'dart:typed_data';

import '../novel/novel_document.dart';
import 'export_models.dart';

/// 段首缩进（两个全角空格，与阅读器一致）。
const _indent = '　　';

/// 章节之间的分隔线。
const _rule = '────────────';

/// 生成 TXT 导出文本：头部（书名 / 作者 / 来源 / 导出时间 / 简介），然后逐章“标题 + 正文”。
///
/// 正文按块输出：段落一行（正文与引用段首缩进，标题不缩进），`rt` 注音丢弃只保留基字；
/// 图片输出为 `［图片：alt］` 占位，分隔线为 `* * *`。换行统一为 `\n`。
String buildNovelTxtText(ExportBook book) {
  final info = book.info;
  final author = _oneLine(info.author ?? '');
  final out = StringBuffer()
    ..writeln('书名：${_oneLine(info.title)}')
    ..writeln('作者：${author.isEmpty ? '未知' : author}')
    ..writeln('来源：${_oneLine(info.sourceName)}')
    ..writeln('导出时间：${formatExportTime(info.exportedAt)}');
  final description = info.description?.trim();
  if (description != null && description.isNotEmpty) {
    out
      ..writeln()
      ..writeln('简介：');
    for (final line in novelBlocksFromText(description)) {
      out.writeln('$_indent${line.plainText}');
    }
  }
  if (book.skipped.isNotEmpty) {
    out
      ..writeln()
      ..writeln('以下 ${book.skipped.length} 章导出失败，未包含在本文件中：');
    for (final t in book.skipped) {
      out.writeln('$_indent${_oneLine(t)}');
    }
  }
  for (final chapter in book.chapters) {
    out
      ..writeln()
      ..writeln(_rule)
      ..writeln()
      ..writeln(_oneLine(chapter.title))
      ..writeln();
    for (final block in chapter.content.blocks) {
      out.writeln(_blockText(block));
    }
  }
  return out.toString();
}

/// UTF-8 编码的 TXT 文件字节；[bom] 为 true 时带 UTF-8 BOM（兼容旧版 Windows 记事本）。
Uint8List buildNovelTxt(ExportBook book, {bool bom = false}) {
  final body = utf8.encode(buildNovelTxtText(book));
  if (!bom) return body;
  return Uint8List(body.length + 3)
    ..setAll(0, const [0xEF, 0xBB, 0xBF])
    ..setAll(3, body);
}

String _blockText(NovelBlock block) => switch (block) {
  NovelParagraph(:final kind) when kind.isHeading => novelSpansText(block),
  NovelParagraph() => '$_indent${novelSpansText(block)}',
  NovelImage(:final alt) => alt == null ? '［图片］' : '［图片：${_oneLine(alt)}］',
  NovelDivider() => '* * *',
};

/// 段落的纯文本：`rt` 注音丢弃（ruby 只取正文）。
String novelSpansText(NovelParagraph p) =>
    _oneLine(p.spans.where((s) => !s.annotation).map((s) => s.text).join());

/// 元数据或段落中残留的换行折叠为空格（段落本身不含换行，保险起见）。
String _oneLine(String s) => s.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
