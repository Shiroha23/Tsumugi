import 'dart:convert';

import 'download_paths.dart';

/// 下载的媒体类型（第一期只有漫画与小说）。
enum DownloadKind { comic, novel }

/// 一个文件的记录：来源标识与写完后的本地文件名（尚未写完时为 null）。
final class DownloadFileEntry {
  const DownloadFileEntry(this.key, [this.file, this.skipped = false]);

  /// 见 [imageSourceKey]。
  final String key;

  /// 相对 unit 目录的文件名（[isValidDownloadFileName]）；未下载或被跳过时为 null。
  final String? file;

  /// 小说图片因超过单张 / 合计 / 数量上限而跳过（保留占位，续传时不再请求）。
  final bool skipped;

  DownloadFileEntry withFile(String? file) => DownloadFileEntry(key, file);

  DownloadFileEntry asSkipped() => DownloadFileEntry(key, null, true);
}

/// unit 目录中的 `unit.json`（docs/architecture.md §4.5）。
///
/// - [files]：按序列出每个文件的来源标识与本地文件名。漫画是各页；小说是正文图片（按首次出现顺序、去重）。
/// - [images]：小说正文图片的“原地址 → 本地文件名”映射（只含已下载的图片）。
///
/// 读取时严格校验：任何字段类型不符、文件名不是本客户端生成的形式，都视为损坏（[FormatException]）。
final class UnitManifest {
  const UnitManifest({
    required this.kind,
    required this.files,
    this.images = const {},
  });

  static const version = 1;

  final DownloadKind kind;
  final List<DownloadFileEntry> files;
  final Map<String, String> images;

  List<String> get keys => [for (final f in files) f.key];

  /// 与 [other] 的来源标识列表完全一致（数量、顺序、每一项）。
  bool sameSources(List<String> other) {
    if (other.length != files.length) return false;
    for (var i = 0; i < other.length; i++) {
      if (other[i] != files[i].key) return false;
    }
    return true;
  }

  UnitManifest copyWith({
    List<DownloadFileEntry>? files,
    Map<String, String>? images,
  }) => UnitManifest(
    kind: kind,
    files: files ?? this.files,
    images: images ?? this.images,
  );

  String encode() => jsonEncode({
    'version': version,
    'kind': kind.name,
    'files': [
      for (final f in files)
        {'key': f.key, 'file': f.file, if (f.skipped) 'skip': true},
    ],
    if (kind == DownloadKind.novel) 'images': images,
  });

  static final _key = RegExp(r'^[0-9a-f]{64}$');

  static UnitManifest decode(String text) {
    final json = jsonDecode(text);
    if (json is! Map || json['version'] != version) {
      throw const FormatException('unit.json: 版本不符');
    }
    final kind = switch (json['kind']) {
      'comic' => DownloadKind.comic,
      'novel' => DownloadKind.novel,
      _ => throw const FormatException('unit.json: kind'),
    };
    final rawFiles = json['files'];
    if (rawFiles is! List) throw const FormatException('unit.json: files');
    final files = <DownloadFileEntry>[];
    for (final f in rawFiles) {
      if (f is! Map) throw const FormatException('unit.json: file');
      final key = f['key'];
      final file = f['file'];
      if (key is! String || !_key.hasMatch(key)) {
        throw const FormatException('unit.json: key');
      }
      if (file != null && (file is! String || !isValidDownloadFileName(file))) {
        throw const FormatException('unit.json: file name');
      }
      final skip = f['skip'];
      if (skip != null && skip != true) {
        throw const FormatException('unit.json: skip');
      }
      files.add(DownloadFileEntry(key, file as String?, skip == true));
    }
    final images = <String, String>{};
    if (kind == DownloadKind.novel) {
      final raw = json['images'];
      if (raw is! Map) throw const FormatException('unit.json: images');
      final known = {for (final f in files) ?f.file};
      for (final MapEntry(:key, :value) in raw.entries) {
        if (key is! String || value is! String || !known.contains(value)) {
          throw const FormatException('unit.json: image map');
        }
        images[key] = value;
      }
    }
    return UnitManifest(kind: kind, files: files, images: images);
  }
}
