import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'download_paths.dart';
import 'unit_manifest.dart';

/// 下载目录的文件操作（docs/architecture.md §4.5）。路径只由 [unitPathSegments] 等生成。
///
/// 写入一律先写 `*.part` 临时文件，校验长度后改名为正式文件名；unit 目录中的完成标记
/// [doneFileName] 只在全部文件写完后写入，没有完成标记的 unit 视为未下载。
class DownloadStore {
  DownloadStore(this._root);

  final FutureOr<Directory> Function() _root;
  Future<Directory>? _rootDir;

  Future<Directory> root() => _rootDir ??= Future(() async => await _root());

  Future<Directory> _dir(List<String> segments) async => Directory(
    [(await root()).path, ...segments].join(Platform.pathSeparator),
  );

  Future<Directory> unitDir(String sourceId, String itemId, String unitId) =>
      _dir(unitPathSegments(sourceId, itemId, unitId));

  Future<Directory> itemDir(String sourceId, String itemId) =>
      _dir(itemPathSegments(sourceId, itemId));

  Future<Directory> sourceDir(String sourceId) => _dir([pathHash(sourceId)]);

  static File fileIn(Directory dir, String name) =>
      File('${dir.path}${Platform.pathSeparator}$name');

  /// 读取 `unit.json`；不存在时返回 null，损坏时抛出 [FormatException]。
  static Future<UnitManifest?> readManifest(Directory dir) async {
    final f = fileIn(dir, unitFileName);
    if (!await f.exists()) return null;
    return UnitManifest.decode(await f.readAsString());
  }

  static Future<void> writeManifest(Directory dir, UnitManifest m) =>
      writeText(dir, unitFileName, m.encode());

  static Future<void> writeText(Directory dir, String name, String text) =>
      writeBytes(dir, name, utf8.encode(text));

  /// 写入 [name]：先写临时文件，确认长度一致后改名（覆盖旧文件）。
  static Future<void> writeBytes(
    Directory dir,
    String name,
    Uint8List bytes,
  ) async {
    await dir.create(recursive: true);
    final part = fileIn(dir, '$name$partSuffix');
    await part.writeAsBytes(bytes, flush: true);
    if (await part.length() != bytes.length) {
      await _tryDelete(part);
      throw FileSystemException('写入长度不符', part.path);
    }
    await part.rename(fileIn(dir, name).path);
  }

  static Future<bool> isDone(Directory dir) =>
      fileIn(dir, doneFileName).exists();

  static Future<void> markDone(Directory dir) =>
      writeText(dir, doneFileName, 'done');

  /// 删除 unit 目录中的全部内容（来源变化时从头下载）。
  static Future<void> clear(Directory dir) => _tryDeleteDir(dir);

  static Future<void> _tryDelete(File f) async {
    try {
      await f.delete();
    } on FileSystemException {
      // 已不存在。
    }
  }

  static Future<void> _tryDeleteDir(Directory d) async {
    try {
      if (await d.exists()) await d.delete(recursive: true);
    } on FileSystemException {
      // 已不存在或正被占用；下次删除 / 清空时再试。
    }
  }

  Future<void> deleteUnit(
    String sourceId,
    String itemId,
    String unitId,
  ) async => _tryDeleteDir(await unitDir(sourceId, itemId, unitId));

  Future<void> deleteItem(String sourceId, String itemId) async =>
      _tryDeleteDir(await itemDir(sourceId, itemId));

  Future<void> deleteSource(String sourceId) async =>
      _tryDeleteDir(await sourceDir(sourceId));

  Future<void> deleteAll() async => _tryDeleteDir(await root());

  /// 下载目录的总占用（字节）。
  Future<int> totalBytes() async {
    final dir = await root();
    if (!await dir.exists()) return 0;
    var total = 0;
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is File) {
        try {
          total += await e.length();
        } on FileSystemException {
          // 刚被删除。
        }
      }
    }
    return total;
  }
}
