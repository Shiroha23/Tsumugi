/// 按 WHATWG Encoding Standard 解码字节为文本。
///
/// 纯 Dart 实现，不依赖平台编码库；索引数据见 `whatwg_indexes.dart`（由
/// `tool/encoding/gen_whatwg_indexes.dart` 生成）。所有解码器遇到非法字节都输出 U+FFFD，不抛异常。
///
/// 支持：utf-8、utf-16le / utf-16be、gb18030（含 gbk / gb2312 等标签）、big5、shift_jis、
/// euc-kr、x-user-defined，以及全部 WHATWG 单字节编码（windows-1252 / iso-8859-* / koi8-* 等，
/// `latin1` / `ascii` 等标签按 windows-1252）。不支持：euc-jp、iso-2022-jp 与 replacement 类编码。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart' show ZLibDecoder;

import 'whatwg_indexes.dart';

const _replacement = 0xFFFD;

/// 把编码标签规范化为本模块的规范名（如 `GB2312` → `gb18030`、`latin1` → `windows-1252`）；
/// 不支持或未知的标签返回 null。
String? normalizeCharset(String label) {
  final l = label.trim().toLowerCase();
  if (l.isEmpty) return null;
  return whatwgLabels[l];
}

/// 用规范名 [encoding]（[normalizeCharset] 的结果）解码 [bytes]。
///
/// 只去掉与编码一致的 BOM（utf-8 的 EF BB BF、utf-16 的 FF FE / FE FF）。
String decodeBytes(List<int> bytes, String encoding) {
  switch (encoding) {
    case 'utf-8':
      final skip = _hasUtf8Bom(bytes) ? 3 : 0;
      return utf8.decode(
        skip == 0 ? bytes : bytes.sublist(skip),
        allowMalformed: true,
      );
    case 'utf-16le' || 'utf-16be':
      return _decodeUtf16(bytes, bigEndian: encoding == 'utf-16be');
    case 'gb18030':
      return _decodeGb18030(bytes);
    case 'big5':
      return _decodeBig5(bytes);
    case 'shift_jis':
      return _decodeShiftJis(bytes);
    case 'euc-kr':
      return _decodeEucKr(bytes);
    case 'x-user-defined':
      return String.fromCharCodes([
        for (final b in bytes) b < 0x80 ? b : 0xF780 + b - 0x80,
      ]);
  }
  final table = singleByteTables[encoding];
  if (table == null) {
    throw ArgumentError.value(encoding, 'encoding', 'unsupported encoding');
  }
  final units = Uint16List(bytes.length);
  for (var i = 0; i < bytes.length; i++) {
    final b = bytes[i];
    units[i] = b < 0x80 ? b : table.codeUnitAt(b - 0x80);
  }
  return String.fromCharCodes(units);
}

/// BOM 对应的编码（utf-8 / utf-16le / utf-16be），没有 BOM 时返回 null。
String? bomEncoding(List<int> bytes) {
  if (_hasUtf8Bom(bytes)) return 'utf-8';
  if (bytes.length >= 2) {
    if (bytes[0] == 0xFE && bytes[1] == 0xFF) return 'utf-16be';
    if (bytes[0] == 0xFF && bytes[1] == 0xFE) return 'utf-16le';
  }
  return null;
}

bool _hasUtf8Bom(List<int> b) =>
    b.length >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF;

// --- 输出缓冲 -------------------------------------------------------------------

class _Out {
  final _buf = StringBuffer();
  final _units = <int>[];

  void add(int codePoint) {
    if (codePoint > 0xFFFF) {
      final c = codePoint - 0x10000;
      _units
        ..add(0xD800 | (c >> 10))
        ..add(0xDC00 | (c & 0x3FF));
    } else {
      _units.add(codePoint);
    }
    if (_units.length >= 4096) _flush();
  }

  void _flush() {
    _buf.write(String.fromCharCodes(_units));
    _units.clear();
  }

  @override
  String toString() {
    _flush();
    return _buf.toString();
  }
}

// --- 索引 ---------------------------------------------------------------------

/// 解压生成文件中的多字节索引：码点差值的 zigzag varint 序列，经 zlib 压缩、base64 编码。
Uint32List _unpack(String data, int length) {
  final bytes = const ZLibDecoder().decodeBytes(base64.decode(data));
  final out = Uint32List(length);
  var pos = 0;
  var prev = 0;
  for (var i = 0; i < length; i++) {
    var z = 0;
    var shift = 0;
    int b;
    do {
      b = bytes[pos++];
      z |= (b & 0x7F) << shift;
      shift += 7;
    } while (b & 0x80 != 0);
    prev += z.isEven ? z >> 1 : -((z + 1) >> 1);
    out[i] = prev;
  }
  return out;
}

final _gb18030Index = _unpack(gb18030IndexData, gb18030IndexLength);
final _big5Index = _unpack(big5IndexData, big5IndexLength);
final _jis0208Index = _unpack(jis0208IndexData, jis0208IndexLength);
final _eucKrIndex = _unpack(eucKrIndexData, eucKrIndexLength);

/// 指针 → 码点；越界或无映射返回 null。
int? _lookup(Uint32List index, int pointer) {
  if (pointer < 0 || pointer >= index.length) return null;
  final v = index[pointer];
  return v == 0 ? null : v;
}

bool _isAscii(int b) => b < 0x80;

// --- gb18030（含 GBK） ---------------------------------------------------------

int? _gb18030RangesCodePoint(int pointer) {
  if ((pointer > 39419 && pointer < 189000) || pointer > 1237575) return null;
  if (pointer >= 189000) return 0x10000 + pointer - 189000;
  if (pointer == 7457) return 0xE7C7;
  // 最后一个偏移 ≤ pointer 的区间（gb18030Ranges 为成对的 [偏移, 码点]）。
  var lo = 0;
  var hi = gb18030Ranges.length ~/ 2 - 1;
  while (lo < hi) {
    final mid = (lo + hi + 1) >> 1;
    if (gb18030Ranges[mid * 2] <= pointer) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  return gb18030Ranges[lo * 2 + 1] + pointer - gb18030Ranges[lo * 2];
}

String _decodeGb18030(List<int> bytes) {
  final out = _Out();
  var first = 0, second = 0, third = 0;
  var i = 0;
  while (i < bytes.length) {
    final b = bytes[i];
    if (third != 0) {
      if (b < 0x30 || b > 0x39) {
        // 把 second、third 与当前字节放回输入流。
        out.add(_replacement);
        i -= 2;
        first = second = third = 0;
        continue;
      }
      final cp = _gb18030RangesCodePoint(
        ((first - 0x81) * (10 * 126 * 10)) +
            ((second - 0x30) * (10 * 126)) +
            ((third - 0x81) * 10) +
            b -
            0x30,
      );
      first = second = third = 0;
      out.add(cp ?? _replacement);
      i++;
      continue;
    }
    if (second != 0) {
      if (b >= 0x81 && b <= 0xFE) {
        third = b;
        i++;
        continue;
      }
      out.add(_replacement);
      i -= 1; // 放回 second 与当前字节
      first = second = 0;
      continue;
    }
    if (first != 0) {
      if (b >= 0x30 && b <= 0x39) {
        second = b;
        i++;
        continue;
      }
      final lead = first;
      first = 0;
      int? cp;
      if ((b >= 0x40 && b <= 0x7E) || (b >= 0x80 && b <= 0xFE)) {
        final offset = b < 0x7F ? 0x40 : 0x41;
        cp = _lookup(_gb18030Index, (lead - 0x81) * 190 + (b - offset));
      }
      if (cp != null) {
        out.add(cp);
        i++;
        continue;
      }
      out.add(_replacement);
      if (!_isAscii(b)) i++; // ASCII 字节放回输入流
      continue;
    }
    if (_isAscii(b)) {
      out.add(b);
    } else if (b == 0x80) {
      out.add(0x20AC);
    } else if (b == 0xFF) {
      out.add(_replacement);
    } else {
      first = b;
    }
    i++;
  }
  if (first != 0 || second != 0 || third != 0) out.add(_replacement);
  return out.toString();
}

// --- Big5 ---------------------------------------------------------------------

String _decodeBig5(List<int> bytes) {
  final out = _Out();
  var lead = 0;
  for (var i = 0; i < bytes.length; i++) {
    final b = bytes[i];
    if (lead != 0) {
      final l = lead;
      lead = 0;
      int? pointer;
      if ((b >= 0x40 && b <= 0x7E) || (b >= 0xA1 && b <= 0xFE)) {
        pointer = (l - 0x81) * 157 + (b - (b < 0x7F ? 0x40 : 0x62));
      }
      switch (pointer) {
        case 1133:
          out
            ..add(0x00CA)
            ..add(0x0304);
          continue;
        case 1135:
          out
            ..add(0x00CA)
            ..add(0x030C);
          continue;
        case 1164:
          out
            ..add(0x00EA)
            ..add(0x0304);
          continue;
        case 1166:
          out
            ..add(0x00EA)
            ..add(0x030C);
          continue;
      }
      final cp = pointer == null ? null : _lookup(_big5Index, pointer);
      if (cp != null) {
        out.add(cp);
        continue;
      }
      out.add(_replacement);
      if (_isAscii(b)) out.add(b);
      continue;
    }
    if (_isAscii(b)) {
      out.add(b);
    } else if (b >= 0x81 && b <= 0xFE) {
      lead = b;
    } else {
      out.add(_replacement);
    }
  }
  if (lead != 0) out.add(_replacement);
  return out.toString();
}

// --- Shift_JIS ----------------------------------------------------------------

String _decodeShiftJis(List<int> bytes) {
  final out = _Out();
  var lead = 0;
  for (var i = 0; i < bytes.length; i++) {
    final b = bytes[i];
    if (lead != 0) {
      final l = lead;
      lead = 0;
      int? pointer;
      if ((b >= 0x40 && b <= 0x7E) || (b >= 0x80 && b <= 0xFC)) {
        final offset = b < 0x7F ? 0x40 : 0x41;
        final leadOffset = l < 0xA0 ? 0x81 : 0xC1;
        pointer = (l - leadOffset) * 188 + b - offset;
      }
      if (pointer != null && pointer >= 8836 && pointer <= 10715) {
        out.add(0xE000 - 8836 + pointer);
        continue;
      }
      final cp = pointer == null ? null : _lookup(_jis0208Index, pointer);
      if (cp != null) {
        out.add(cp);
        continue;
      }
      out.add(_replacement);
      if (_isAscii(b)) out.add(b);
      continue;
    }
    if (b <= 0x80) {
      out.add(b);
    } else if (b >= 0xA1 && b <= 0xDF) {
      out.add(0xFF61 - 0xA1 + b);
    } else if ((b >= 0x81 && b <= 0x9F) || (b >= 0xE0 && b <= 0xFC)) {
      lead = b;
    } else {
      out.add(_replacement);
    }
  }
  if (lead != 0) out.add(_replacement);
  return out.toString();
}

// --- EUC-KR -------------------------------------------------------------------

String _decodeEucKr(List<int> bytes) {
  final out = _Out();
  var lead = 0;
  for (var i = 0; i < bytes.length; i++) {
    final b = bytes[i];
    if (lead != 0) {
      final l = lead;
      lead = 0;
      final cp = b >= 0x41 && b <= 0xFE
          ? _lookup(_eucKrIndex, (l - 0x81) * 190 + (b - 0x41))
          : null;
      if (cp != null) {
        out.add(cp);
        continue;
      }
      out.add(_replacement);
      if (_isAscii(b)) out.add(b);
      continue;
    }
    if (_isAscii(b)) {
      out.add(b);
    } else if (b >= 0x81 && b <= 0xFE) {
      lead = b;
    } else {
      out.add(_replacement);
    }
  }
  if (lead != 0) out.add(_replacement);
  return out.toString();
}

// --- UTF-16 -------------------------------------------------------------------

String _decodeUtf16(List<int> bytes, {required bool bigEndian}) {
  final out = _Out();
  var start = 0;
  if (bytes.length >= 2 &&
      bytes[0] == (bigEndian ? 0xFE : 0xFF) &&
      bytes[1] == (bigEndian ? 0xFF : 0xFE)) {
    start = 2;
  }
  int? pendingHigh;
  var i = start;
  for (; i + 1 < bytes.length; i += 2) {
    final u = bigEndian
        ? (bytes[i] << 8) | bytes[i + 1]
        : bytes[i] | (bytes[i + 1] << 8);
    if (pendingHigh != null) {
      if (u >= 0xDC00 && u <= 0xDFFF) {
        out.add(0x10000 + ((pendingHigh - 0xD800) << 10) + (u - 0xDC00));
        pendingHigh = null;
        continue;
      }
      out.add(_replacement);
      pendingHigh = null;
    }
    if (u >= 0xD800 && u <= 0xDBFF) {
      pendingHigh = u;
    } else if (u >= 0xDC00 && u <= 0xDFFF) {
      out.add(_replacement);
    } else {
      out.add(u);
    }
  }
  if (pendingHigh != null || i < bytes.length) out.add(_replacement);
  return out.toString();
}
