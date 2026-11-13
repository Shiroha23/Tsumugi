import 'dart:typed_data';

import '../../sources/model/common.dart';
import '../novel/novel_document.dart';

/// 小说导出格式。
enum ExportFormat {
  txt('TXT', 'txt', 'text/plain'),
  epub('EPUB', 'epub', 'application/epub+zip');

  const ExportFormat(this.label, this.extension, this.mimeType);

  final String label;
  final String extension;
  final String mimeType;
}

/// 详情中的线路：有 `groups`（多线路）时按线路，否则把 `units` 视为唯一一组“默认”。
List<UnitGroup> unitGroupsOf(Detail detail) {
  final groups = detail.groups;
  if (groups != null && groups.isNotEmpty) return groups;
  return [UnitGroup(name: '默认', units: detail.units)];
}

/// 导出范围：第 [group] 条线路（见 [unitGroupsOf]）中下标 [start]..[end]（含两端）的章节；
/// [start] / [end] 省略时分别为该线路的第一章 / 最后一章，都省略即“整条线路”。
final class ExportRange {
  const ExportRange({this.group = 0, this.start, this.end});

  final int group;
  final int? start;
  final int? end;

  /// 按本范围从 [detail] 中取出章节（越界的下标会被收紧到有效范围）。
  List<Unit> select(Detail detail) {
    final groups = unitGroupsOf(detail);
    final units = groups[group.clamp(0, groups.length - 1)].units;
    if (units.isEmpty) return const [];
    final a = (start ?? 0).clamp(0, units.length - 1);
    final b = (end ?? units.length - 1).clamp(0, units.length - 1);
    return a <= b ? units.sublist(a, b + 1) : units.sublist(b, a + 1);
  }
}

/// 写入导出文件头部 / 元数据的作品信息。
final class ExportBookInfo {
  const ExportBookInfo({
    required this.sourceId,
    required this.itemId,
    required this.title,
    required this.sourceName,
    required this.exportedAt,
    this.author,
    this.description,
    this.language = 'zh',
  });

  final String sourceId;
  final String itemId;
  final String title;
  final String? author;
  final String? description;

  /// 来源源的名称（清单 `name`）。
  final String sourceName;
  final DateTime exportedAt;

  /// BCP 47 语言标签（清单 `lang`），用于 EPUB 的 `dc:language`。
  final String language;
}

/// 成功取得的一章。
final class ExportedChapter {
  const ExportedChapter({
    required this.unitId,
    required this.title,
    required this.content,
  });

  final String unitId;
  final String title;
  final NovelChapter content;
}

/// 封面图片（经统一图片加载取得的字节）。
final class ExportImage {
  const ExportImage(this.bytes, this.mediaType, this.extension);

  final Uint8List bytes;
  final String mediaType;
  final String extension;

  /// 按文件头识别 EPUB 支持的核心图片格式；不认识时返回 null。
  static ExportImage? sniff(Uint8List bytes) {
    bool at(int offset, List<int> magic) {
      if (bytes.length < offset + magic.length) return false;
      for (var i = 0; i < magic.length; i++) {
        if (bytes[offset + i] != magic[i]) return false;
      }
      return true;
    }

    if (at(0, const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
      return ExportImage(bytes, 'image/png', 'png');
    }
    if (at(0, const [0xFF, 0xD8, 0xFF])) {
      return ExportImage(bytes, 'image/jpeg', 'jpg');
    }
    if (at(0, const [0x47, 0x49, 0x46, 0x38])) {
      return ExportImage(bytes, 'image/gif', 'gif');
    }
    if (at(0, const [0x52, 0x49, 0x46, 0x46]) &&
        at(8, const [0x57, 0x45, 0x42, 0x50])) {
      return ExportImage(bytes, 'image/webp', 'webp');
    }
    return null;
  }
}

/// 交给 TXT / EPUB 生成器的全部数据。
final class ExportBook {
  const ExportBook({
    required this.info,
    required this.chapters,
    this.skipped = const [],
    this.cover,
  });

  final ExportBookInfo info;
  final List<ExportedChapter> chapters;

  /// 导出失败、被跳过的章节标题（写进头部，提示读者内容不完整）。
  final List<String> skipped;
  final ExportImage? cover;
}

/// 生成好的导出文件。
final class ExportFile {
  const ExportFile({
    required this.fileName,
    required this.format,
    required this.bytes,
  });

  final String fileName;
  final ExportFormat format;
  final Uint8List bytes;
}

/// Windows / Android / iOS 文件名中不允许的字符与控制字符。
final _illegalFileChars = RegExp(r'[\\/:*?"<>|\x00-\x1F\x7F]');

/// Windows 的保留设备名（不区分大小写，带扩展名也不行）。
final _reservedNames = RegExp(
  r'^(con|prn|aux|nul|com[0-9]|lpt[0-9])$',
  caseSensitive: false,
);

/// 由书名生成安全的文件名（不含扩展名）：替换非法字符，去掉首尾空白与结尾的点，
/// 避开保留名，并限制长度（按 UTF-16 码元，不拆开代理对）。
String safeFileStem(String title, {int maxLength = 80}) {
  var s = title
      .replaceAll(_illegalFileChars, '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (s.length > maxLength) {
    var cut = maxLength;
    final unit = s.codeUnitAt(cut - 1);
    if (unit >= 0xD800 && unit <= 0xDBFF) cut--;
    s = s.substring(0, cut).trim();
  }
  s = s.replaceFirst(RegExp(r'[. ]+$'), '');
  if (s.isEmpty) return 'novel';
  if (_reservedNames.hasMatch(s)) return '_$s';
  return s;
}

/// 两位数补零的本地时间，例如 `2026-11-13 08:05`。
String formatExportTime(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}
