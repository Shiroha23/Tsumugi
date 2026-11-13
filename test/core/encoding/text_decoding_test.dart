import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/encoding/text_decoding.dart';

String decode(List<int> bytes, String label) =>
    decodeBytes(bytes, normalizeCharset(label)!);

void main() {
  group('normalizeCharset（WHATWG 标签）', () {
    test('GB 系列统一按 gb18030', () {
      for (final l in [
        'gb2312',
        'GBK',
        'x-gbk',
        'GB18030',
        'csGB2312',
        'chinese',
      ]) {
        expect(normalizeCharset(l), 'gb18030', reason: l);
      }
    });

    test('常见别名', () {
      expect(normalizeCharset(' UTF8 '), 'utf-8');
      expect(normalizeCharset('big5-hkscs'), 'big5');
      expect(normalizeCharset('Shift-JIS'), 'shift_jis');
      expect(normalizeCharset('sjis'), 'shift_jis');
      expect(normalizeCharset('windows-31j'), 'shift_jis');
      expect(normalizeCharset('ks_c_5601-1987'), 'euc-kr');
      expect(normalizeCharset('windows-949'), 'euc-kr');
      expect(normalizeCharset('ISO-8859-1'), 'windows-1252');
      expect(normalizeCharset('latin1'), 'windows-1252');
      expect(normalizeCharset('us-ascii'), 'windows-1252');
      expect(normalizeCharset('utf-16'), 'utf-16le');
      expect(normalizeCharset('cp1251'), 'windows-1251');
    });

    test('未知或不支持的标签返回 null', () {
      for (final l in [
        '',
        'utf-9',
        'euc-jp',
        'iso-2022-jp',
        'hz-gb-2312',
        'gbk2',
      ]) {
        expect(normalizeCharset(l), isNull, reason: l);
      }
    });
  });

  group('多字节解码', () {
    test('GBK（含 GB2312 之外的字）', () {
      expect(decode([0xD6, 0xD0, 0xCE, 0xC4, 0x88, 0xD2], 'gbk'), '中文堃');
    });

    test('GB18030 四字节序列与 0x80', () {
      expect(decode([0x95, 0x32, 0x82, 0x36], 'gb18030'), '𠀀'); // U+20000
      expect(decode([0x81, 0x30, 0x8A, 0x32], 'gb18030'), 'å'); // 区间表
      expect(decode([0x80], 'gbk'), '€');
    });

    test('Big5（含 HKSCS 扩展 B 字与组合字符指针）', () {
      expect(decode([0xC3, 0xFA, 0xB4, 0xE4], 'big5'), '霧港');
      expect(decode([0x87, 0x45], 'big5'), '𧉧');
      expect(decode([0x88, 0x62], 'big5'), 'Ê̄'); // 指针 1133
    });

    test('Shift_JIS（含半角片假名）', () {
      expect(
        decode([0x93, 0xFA, 0x96, 0x7B, 0x8C, 0xEA, 0xB1], 'shift_jis'),
        '日本語ｱ',
      );
    });

    test('EUC-KR（含 UHC 扩展）', () {
      expect(
        decode([0xC7, 0xD1, 0xB1, 0xB9, 0xBE, 0xEE, 0x8C, 0x63], 'euc-kr'),
        '한국어똠',
      );
    });

    test('ASCII 原样通过', () {
      final ascii = 'abc <p>123</p>\n'.codeUnits;
      for (final l in ['gbk', 'big5', 'shift_jis', 'euc-kr', 'windows-1252']) {
        expect(decode(ascii, l), 'abc <p>123</p>\n', reason: l);
      }
    });
  });

  group('单字节与 UTF-16', () {
    test('windows-1252：0x80 为 €，latin1 标签同样如此', () {
      expect(decode([0x80, 0xE9], 'windows-1252'), '€é');
      expect(decode([0x80, 0xE9], 'iso-8859-1'), '€é');
    });

    test('其他单字节编码', () {
      expect(decode([0xF6], 'koi8-r'), 'Ж');
      expect(decode([0xC6], 'windows-1251'), 'Ж');
    });

    test('UTF-16LE / BE（含代理对，去掉 BOM）', () {
      expect(
        decode([0xFF, 0xFE, 0x2D, 0x4E, 0x40, 0xD8, 0x00, 0xDC], 'utf-16le'),
        '中𠀀',
      );
      expect(decode([0x4E, 0x2D], 'utf-16be'), '中');
    });

    test('UTF-8 去掉 BOM', () {
      expect(decode([0xEF, 0xBB, 0xBF, ...utf8.encode('中')], 'utf-8'), '中');
    });
  });

  group('非法字节替换为 U+FFFD，不抛异常', () {
    test('GBK：非法尾字节为 ASCII 时保留该字符', () {
      expect(decode([0xD6, 0x20, 0x42], 'gbk'), '� B');
      expect(decode([0xFF, 0x41], 'gbk'), '�A');
    });

    test('GB18030：不完整的四字节序列放回后续字节', () {
      // 0x81 0x30 0x41：第三字节不合法 → U+FFFD，然后 "0A" 原样输出。
      expect(decode([0x81, 0x30, 0x41], 'gb18030'), '�0A');
      // 0x81 0x30 0x81 0x20：第四字节不合法 → U+FFFD，再处理 0x30 0x81 0x20。
      expect(decode([0x81, 0x30, 0x81, 0x20], 'gb18030'), '�0� ');
    });

    test('末尾被截断的多字节序列', () {
      expect(decode([0x41, 0xD6], 'gbk'), 'A�');
      expect(decode([0x95, 0x32, 0x82], 'gb18030'), '�');
      expect(decode([0xC3], 'big5'), '�');
      expect(decode([0x93], 'shift_jis'), '�');
      expect(decode([0xC7], 'euc-kr'), '�');
      expect(decode([0x2D, 0x4E, 0x40], 'utf-16le'), '中�');
    });

    test('无映射的指针', () {
      expect(decode([0xA1, 0x30], 'big5'), '�0');
      expect(decode([0xC7, 0x20], 'euc-kr'), '� ');
      expect(decode([0x81, 0xFD], 'shift_jis'), '�');
      expect(decode([0x00, 0xDC, 0x41, 0x00], 'utf-16le'), '�A');
    });

    test('UTF-8 非法字节', () {
      expect(decode([0x41, 0xC3, 0x28], 'utf-8'), 'A�(');
    });

    test('单字节编码中未定义的字节', () {
      expect(decode([0xA1], 'windows-874'), 'ก');
      expect(decode([0xDB], 'windows-874'), '�');
    });
  });

  test('不支持的规范名抛出 ArgumentError（调用方应先 normalizeCharset）', () {
    expect(() => decodeBytes([0x41], 'euc-jp'), throwsArgumentError);
  });

  test('bomEncoding', () {
    expect(bomEncoding([0xEF, 0xBB, 0xBF, 0x41]), 'utf-8');
    expect(bomEncoding([0xFF, 0xFE]), 'utf-16le');
    expect(bomEncoding([0xFE, 0xFF]), 'utf-16be');
    expect(bomEncoding([0x41, 0x42, 0x43]), isNull);
  });
}
