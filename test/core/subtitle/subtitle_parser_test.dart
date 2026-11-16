import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/subtitle/subtitle_parser.dart';

const _dir = 'test/fixtures/mock_site/video/subs';

List<int> _bytes(String name) => File('$_dir/$name').readAsBytesSync();

Duration _s(num seconds) => Duration(milliseconds: (seconds * 1000).round());

SubtitleDocument _parseFixture(String name, {SubtitleFormat? declared}) =>
    parseSubtitle(decodeSubtitle(_bytes(name)), declared: declared);

void main() {
  group('解码', () {
    test('UTF-8 带 BOM', () {
      final text = decodeSubtitle(_bytes('zh.srt'));
      expect(text, contains('第一段：彩条开始'));
    });

    test('GBK（无 BOM、无 charset）按 GB18030 回退', () {
      final text = decodeSubtitle(_bytes('zh_gbk.srt'));
      expect(text, contains('GBK 字幕：第一段'));
      expect(text, isNot(contains('�')));
    });

    test('合法 UTF-8 不回退', () {
      final bytes = utf8.encode('1\n00:00:00,000 --> 00:00:01,000\n日本語\n');
      expect(decodeSubtitle(bytes), contains('日本語'));
    });

    test('Content-Type 的 charset 优先于回退', () {
      final bytes = latin1.encode(
        '1\n00:00:00,000 --> 00:00:01,000\ncaf\xe9\n',
      );
      expect(
        decodeSubtitle(bytes, contentType: 'text/plain; charset=iso-8859-1'),
        contains('café'),
      );
    });

    test('源声明的 charset 最优先', () {
      final big5 = [0xA4, 0xA4, 0xA4, 0xE5]; // “中文”（Big5）
      final bytes = [
        ...ascii.encode('1\n00:00:00,000 --> 00:00:01,000\n'),
        ...big5,
      ];
      expect(
        decodeSubtitle(
          bytes,
          charset: 'big5',
          contentType: 'text/plain; charset=utf-8',
        ),
        endsWith('中文'),
      );
    });

    test('UTF-16 BOM', () {
      final text = '1\n00:00:00,000 --> 00:00:01,000\nUTF-16 字幕\n';
      final bytes = [0xFF, 0xFE];
      for (final unit in text.codeUnits) {
        bytes
          ..add(unit & 0xFF)
          ..add(unit >> 8);
      }
      final doc = parseSubtitle(decodeSubtitle(bytes));
      expect(doc.cues.single.text, 'UTF-16 字幕');
    });

    test('二进制（含 NUL）拒绝', () {
      expect(
        () => decodeSubtitle([0x31, 0x0A, 0x00, 0x00, 0x41]),
        throwsA(isA<SubtitleFormatException>()),
      );
    });

    test('没有 BOM 的 UTF-16 拒绝（解码后含 NUL）', () {
      final bytes = <int>[];
      for (final unit in 'WEBVTT\n'.codeUnits) {
        bytes
          ..add(unit)
          ..add(0);
      }
      expect(
        () => decodeSubtitle(bytes),
        throwsA(isA<SubtitleFormatException>()),
      );
    });
  });

  group('格式识别', () {
    test('按内容识别', () {
      expect(sniffSubtitleFormat('﻿WEBVTT\n\n'), SubtitleFormat.vtt);
      expect(sniffSubtitleFormat('WEBVTT'), SubtitleFormat.vtt);
      expect(sniffSubtitleFormat('  \n[Script Info]\n'), SubtitleFormat.ass);
      expect(sniffSubtitleFormat('[script info]\n'), SubtitleFormat.ass);
      expect(
        sniffSubtitleFormat('1\r\n00:00:01,000 --> 00:00:02,000\r\nx'),
        SubtitleFormat.srt,
      );
      expect(
        sniffSubtitleFormat('00:00:01,000 --> 00:00:02,000\nx'),
        SubtitleFormat.srt,
      );
    });

    test('识别不了的拒绝', () {
      for (final text in [
        '',
        'WEBVTTX\n',
        '#EXTM3U\n#EXTINF:1,\nseg.ts\n',
        '{"subtitles": []}',
        '<?xml version="1.0"?><tt xmlns="http://www.w3.org/ns/ttml"></tt>',
        '1\nhello\n',
      ]) {
        expect(sniffSubtitleFormat(text), isNull, reason: text);
        expect(
          () => parseSubtitle(text),
          throwsA(isA<SubtitleFormatException>()),
          reason: text,
        );
      }
    });

    test('伪装成 srt 的 HTML 拒绝', () {
      expect(
        () => _parseFixture('bad.srt', declared: SubtitleFormat.srt),
        throwsA(
          isA<SubtitleFormatException>().having(
            (e) => e.message,
            'message',
            '无法识别的字幕格式',
          ),
        ),
      );
    });

    test('与声明的格式不符时拒绝', () {
      expect(
        () => _parseFixture('en.vtt', declared: SubtitleFormat.srt),
        throwsA(isA<SubtitleFormatException>()),
      );
      expect(
        _parseFixture('en.vtt', declared: SubtitleFormat.vtt).format,
        SubtitleFormat.vtt,
      );
    });

    test('format 取值', () {
      expect(SubtitleFormat.parse('SRT'), SubtitleFormat.srt);
      expect(SubtitleFormat.parse('ssa'), SubtitleFormat.ass);
      expect(SubtitleFormat.parse('webvtt'), SubtitleFormat.vtt);
      expect(SubtitleFormat.parse('ttml'), isNull);
      expect(SubtitleFormat.parse(null), isNull);
    });
  });

  group('srt', () {
    test('fixture：BOM、CRLF、标签', () {
      final doc = _parseFixture('zh.srt');
      expect(doc.format, SubtitleFormat.srt);
      expect(doc.cues, [
        SubtitleCue(_s(0), _s(2), '第一段：彩条开始'),
        SubtitleCue(_s(2), _s(4), '第二段：画面中间'),
        SubtitleCue(_s(4), _s(6), '第三段：结尾\n（两行字幕）'),
      ]);
    });

    test('GBK fixture', () {
      final doc = _parseFixture('zh_gbk.srt');
      expect(doc.cues.map((c) => c.text), [
        'GBK 字幕：第一段',
        'GBK 字幕：第二段',
        'GBK 字幕：第三段',
      ]);
    });

    test('宽松的时间写法；无效条目丢弃；按开始时间排序', () {
      final doc = parseSubtitle('''
3
0:00:05.5 --> 0:00:06,25
later

1
00:00:01,000 --> 00:00:02,000
first

2
00:00:03,000 --> 00:00:02,000
end before start

x
00:61:00,000 --> 00:62:00,000
bad minutes

4
00:00:07,000 --> 00:00:08,000

''');
      expect(doc.cues, [
        SubtitleCue(_s(1), _s(2), 'first'),
        SubtitleCue(_s(5.5), _s(6.25), 'later'),
      ]);
    });

    test('只有无效条目时拒绝', () {
      expect(
        () => parseSubtitle('1\n00:00:02,000 --> 00:00:01,000\nx\n'),
        throwsA(isA<SubtitleFormatException>()),
      );
    });
  });

  group('vtt', () {
    test('fixture：头部、NOTE / STYLE、标识、标签、实体', () {
      final doc = _parseFixture('en.vtt');
      expect(doc.cues, [
        SubtitleCue(_s(0), _s(2), 'Color bars & a tone'),
        SubtitleCue(_s(2), _s(4), 'Second part still'),
        SubtitleCue(_s(4), _s(6), 'Last part <end>'),
      ]);
    });

    test('数字实体：控制字符不解码', () {
      final doc = parseSubtitle(
        'WEBVTT\n\n00:00.000 --> 00:01.000\n&#x4E2D;&#25991; &#0; &#xD800;\n',
      );
      expect(doc.cues.single.text, '中文 &#0; &#xD800;');
    });
  });

  group('ass', () {
    test('fixture：覆盖标签、换行、绘图、Comment、[Fonts]', () {
      final doc = _parseFixture('ja.ass');
      expect(doc.format, SubtitleFormat.ass);
      expect(doc.cues, [
        SubtitleCue(_s(0), _s(2), '一つ目, comma kept\nnext line'),
        SubtitleCue(_s(2), _s(4), '二つ目 です'),
        SubtitleCue(_s(4), _s(6), '三つ目'),
      ]);
    });

    test('按 Format 定位列；SSA 的 Marked 列', () {
      final doc = parseSubtitle('''
[Script Info]
ScriptType: v4.00

[Events]
Format: Marked, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: Marked=0,0:00:01.50,0:00:02.00,Default,,0000,0000,0000,,SSA line
''');
      expect(doc.cues.single, SubtitleCue(_s(1.5), _s(2), 'SSA line'));
    });

    test('Text 不是最后一列、绘图模式未结束', () {
      expect(
        () => parseSubtitle('''
[Script Info]
[Events]
Format: Text, Start, End
Dialogue: x,0:00:00.00,0:00:01.00
'''),
        throwsA(isA<SubtitleFormatException>()),
      );
      final doc = parseSubtitle('''
[Script Info]
[Events]
Format: Start, End, Text
Dialogue: 0:00:00.00,0:00:01.00,visible{\\p99999999999999999999999}m 0 0 l 1 1
''');
      expect(doc.cues.single.text, 'visible');
    });
  });

  group('上限', () {
    test('条数上限', () {
      final b = StringBuffer();
      for (var i = 0; i < maxSubtitleCues + 5; i++) {
        final ms = i * 10;
        b.write(
          '${i + 1}\n'
          '${_srtTime(ms)} --> ${_srtTime(ms + 5)}\n'
          'cue $i\n\n',
        );
      }
      final doc = parseSubtitle(b.toString());
      expect(doc.cues.length, maxSubtitleCues);
    });

    test('单条长度上限', () {
      final doc = parseSubtitle(
        '1\n00:00:00,000 --> 00:00:01,000\n${'长' * (maxSubtitleCueLength + 10)}\n',
      );
      expect(doc.cues.single.text.length, maxSubtitleCueLength);
    });
  });

  group('textAt', () {
    final doc = parseSubtitle('''
1
00:00:00,000 --> 00:00:10,000
long

2
00:00:02,000 --> 00:00:03,000
short

3
00:00:05,000 --> 00:00:06,000
later
''');

    test('按位置取，重叠的按开始时间以换行连接', () {
      expect(doc.textAt(Duration.zero), 'long');
      expect(doc.textAt(_s(2.5)), 'long\nshort');
      expect(doc.textAt(_s(3)), 'long');
      expect(doc.textAt(_s(5.5)), 'long\nlater');
      expect(doc.textAt(_s(10)), '');
      expect(doc.textAt(-_s(1)), '');
    });
  });
}

String _srtTime(int ms) {
  final d = Duration(milliseconds: ms);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.inHours)}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)},'
      '${(ms % 1000).toString().padLeft(3, '0')}';
}
