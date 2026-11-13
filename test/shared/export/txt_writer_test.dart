import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/shared/export/txt_writer.dart';

import 'export_fixtures.dart';

void main() {
  test('头部、章节标题与正文；HTML 转纯文本（br 换行、ruby 取正文、图片占位）', () {
    final text = buildNovelTxtText(sampleBook(skipped: ['第三章 雨季']));
    expect(
      text,
      '书名：青石巷的钟表匠 <测试> & "引号"\n'
      '作者：虚构作者丁\n'
      '来源：Mock 小说\n'
      '导出时间：2026-11-13 08:05\n'
      '\n'
      '简介：\n'
      '　　老钟表匠修好了一只会倒着走的怀表。\n'
      '　　第二段简介。\n'
      '\n'
      '以下 1 章导出失败，未包含在本文件中：\n'
      '　　第三章 雨季\n'
      '\n'
      '────────────\n'
      '\n'
      '第一章 倒走的怀表\n'
      '\n'
      '　　青石巷尽头有一家很小的钟表铺。\n'
      '　　这天傍晚，客人送来一只怀表。\n'
      '\n'
      '────────────\n'
      '\n'
      '第二章 灯塔\n'
      '\n'
      '　　灯塔守夜人在日志里写下：今晚无风。\n'
      '［图片：灯塔］\n'
      '　　他把灯芯剪短了一些。\n'
      '　　海面上一片寂静。\n'
      '小节\n'
      '　　引用粗斜线删\n'
      '* * *\n'
      '　　控制字符\u0001与 <script> 文本\n',
    );
    expect(text, isNot(contains('とうしん')));
    expect(text, isNot(contains('tracker')));
  });

  test('UTF-8 编码；可选 BOM', () {
    final book = sampleBook();
    final plain = buildNovelTxt(book);
    expect(plain.take(3), isNot([0xEF, 0xBB, 0xBF]));
    expect(utf8.decode(plain), buildNovelTxtText(book));

    final withBom = buildNovelTxt(book, bom: true);
    expect(withBom.take(3), [0xEF, 0xBB, 0xBF]);
    expect(withBom.sublist(3), plain);
  });

  test('作者为空时写“未知”，没有简介时不写简介段', () {
    final text = buildNovelTxtText(sampleBook(withMeta: false));
    expect(text, contains('作者：未知\n'));
    expect(text, isNot(contains('简介')));
  });
}
