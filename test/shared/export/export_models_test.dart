import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/shared/export/export_models.dart';
import 'package:tsumugi/sources/model/common.dart';

void main() {
  group('safeFileStem', () {
    test('替换非法字符与控制字符，折叠空白', () {
      expect(safeFileStem('a/b\\c:d*e?f"g<h>i|j'), 'a_b_c_d_e_f_g_h_i_j');
      expect(safeFileStem('书名\u0000\t\n 续'), '书名___ 续');
      expect(safeFileStem('  青石巷  的  钟表匠  '), '青石巷 的 钟表匠');
    });

    test('去掉结尾的点与空格；空名与保留名', () {
      expect(safeFileStem('终章...'), '终章');
      expect(safeFileStem(' . '), 'novel');
      expect(safeFileStem(''), 'novel');
      expect(safeFileStem('CON'), '_CON');
      expect(safeFileStem('lpt1'), '_lpt1');
      expect(safeFileStem('console'), 'console');
    });

    test('限制长度且不拆开代理对', () {
      expect(safeFileStem('字' * 200), '字' * 80);
      final emoji = '${'a' * 79}😀';
      expect(safeFileStem(emoji), 'a' * 79);
    });
  });

  group('ExportRange', () {
    const detail = Detail(
      id: 'b',
      title: 't',
      units: [
        Unit(id: '1', title: '一'),
        Unit(id: '2', title: '二'),
        Unit(id: '3', title: '三'),
      ],
    );
    const grouped = Detail(
      id: 'b',
      title: 't',
      groups: [
        UnitGroup(
          name: '线路一',
          units: [Unit(id: 'a1', title: 'A1')],
        ),
        UnitGroup(
          name: '线路二',
          units: [
            Unit(id: 'b1', title: 'B1'),
            Unit(id: 'b2', title: 'B2'),
          ],
        ),
      ],
    );

    List<String> ids(List<Unit> u) => [for (final x in u) x.id];

    test('全部 / 起止（含两端，可颠倒，越界收紧）', () {
      expect(ids(const ExportRange().select(detail)), ['1', '2', '3']);
      expect(ids(const ExportRange(start: 1, end: 2).select(detail)), [
        '2',
        '3',
      ]);
      expect(ids(const ExportRange(start: 2, end: 0).select(detail)), [
        '1',
        '2',
        '3',
      ]);
      expect(ids(const ExportRange(start: 1, end: 99).select(detail)), [
        '2',
        '3',
      ]);
    });

    test('选中线路', () {
      expect(unitGroupsOf(grouped).map((g) => g.name), ['线路一', '线路二']);
      expect(ids(const ExportRange(group: 1).select(grouped)), ['b1', 'b2']);
      expect(unitGroupsOf(detail).single.name, '默认');
      expect(
        const ExportRange().select(const Detail(id: 'x', title: 'x')),
        isEmpty,
      );
    });
  });

  test('ExportImage.sniff 识别 PNG / JPEG / GIF / WebP', () {
    ExportImage? s(List<int> b) => ExportImage.sniff(Uint8List.fromList(b));
    expect(
      s([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0])?.mediaType,
      'image/png',
    );
    expect(s([0xFF, 0xD8, 0xFF, 0xE0])?.extension, 'jpg');
    expect(s('GIF89a'.codeUnits)?.mediaType, 'image/gif');
    expect(
      s([...'RIFF'.codeUnits, 0, 0, 0, 0, ...'WEBP'.codeUnits])?.mediaType,
      'image/webp',
    );
    expect(s('<svg>'.codeUnits), isNull);
  });

  test('formatExportTime', () {
    expect(formatExportTime(DateTime(2026, 1, 2, 3, 4)), '2026-01-02 03:04');
  });
}
