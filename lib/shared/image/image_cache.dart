import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// 图片缓存键：同一 URL 在不同源下是不同条目（各源的 Cookie / headers 可能不同）。
///
/// 只由 `sourceId` 与 `url` 组成；请求 headers 不参与（同一源同一地址视为同一张图）。
final class ImageCacheKey {
  const ImageCacheKey(this.sourceId, this.url);

  final String sourceId;
  final String url;

  /// 稳定的文件名安全摘要（sha256 十六进制）。
  String get digest =>
      sha256.convert(utf8.encode('$sourceId\n$url')).toString();

  @override
  bool operator ==(Object other) =>
      other is ImageCacheKey && other.sourceId == sourceId && other.url == url;

  @override
  int get hashCode => Object.hash(sourceId, url);

  @override
  String toString() => 'ImageCacheKey($sourceId, $url)';
}

/// 按字节数限制容量的内存 LRU（存放编码后的图片字节，不是解码后的位图）。
class MemoryImageCache {
  MemoryImageCache({this.maxBytes = 64 * 1024 * 1024, this.maxEntryBytes});

  /// 总容量上限。
  final int maxBytes;

  /// 单个条目上限；超过则不进内存缓存。默认为 [maxBytes] 的四分之一。
  final int? maxEntryBytes;

  final _entries = <ImageCacheKey, Uint8List>{};
  int _bytes = 0;

  int get sizeBytes => _bytes;
  int get length => _entries.length;

  Uint8List? get(ImageCacheKey key) {
    final v = _entries.remove(key);
    if (v != null) _entries[key] = v; // 移到末尾 = 最近使用
    return v;
  }

  void put(ImageCacheKey key, Uint8List bytes) {
    remove(key);
    if (bytes.length > (maxEntryBytes ?? maxBytes ~/ 4)) return;
    _entries[key] = bytes;
    _bytes += bytes.length;
    while (_bytes > maxBytes && _entries.isNotEmpty) {
      final oldest = _entries.keys.first;
      _bytes -= _entries.remove(oldest)!.length;
    }
  }

  void remove(ImageCacheKey key) {
    final v = _entries.remove(key);
    if (v != null) _bytes -= v.length;
  }

  void clear() {
    _entries.clear();
    _bytes = 0;
  }
}

/// 磁盘缓存接口；便于测试替换。
abstract interface class DiskImageCache {
  Future<Uint8List?> get(ImageCacheKey key);
  Future<void> put(ImageCacheKey key, Uint8List bytes);
  Future<void> remove(ImageCacheKey key);
  Future<void> clear();
}

/// 不缓存到磁盘（测试或无法取得缓存目录时使用）。
class NoDiskImageCache implements DiskImageCache {
  const NoDiskImageCache();
  @override
  Future<Uint8List?> get(ImageCacheKey key) async => null;
  @override
  Future<void> put(ImageCacheKey key, Uint8List bytes) async {}
  @override
  Future<void> remove(ImageCacheKey key) async {}
  @override
  Future<void> clear() async {}
}

/// 目录下每个条目一个文件（文件名 = [ImageCacheKey.digest]），按总字节数做 LRU 清理。
///
/// 最近使用时间保存在内存索引中，并尽量同步到文件修改时间，
/// 以便下次启动扫描目录时恢复大致的 LRU 顺序。
class FileDiskImageCache implements DiskImageCache {
  FileDiskImageCache(
    Future<Directory> Function() directory, {
    this.maxBytes = 512 * 1024 * 1024,
    DateTime Function()? clock,
  }) : _directory = directory,
       _clock = clock ?? DateTime.now;

  final Future<Directory> Function() _directory;
  final int maxBytes;
  final DateTime Function() _clock;

  Future<_DiskIndex>? _index;

  Future<_DiskIndex> _load() => _index ??= () async {
    final dir = await _directory();
    await dir.create(recursive: true);
    final index = _DiskIndex(dir);
    final found = <(String, int, DateTime)>[];
    await for (final e in dir.list(followLinks: false)) {
      if (e is! File) continue;
      final name = e.uri.pathSegments.last;
      if (name.endsWith('.tmp')) {
        // 上次写入中断留下的临时文件。
        await _tryDelete(e);
        continue;
      }
      try {
        final stat = await e.stat();
        found.add((name, stat.size, stat.modified));
      } on FileSystemException {
        // 忽略无法读取的条目。
      }
    }
    found.sort((a, b) => a.$3.compareTo(b.$3));
    for (final (name, size, _) in found) {
      index.add(name, size);
    }
    await _evict(index);
    return index;
  }();

  /// 当前占用（字节）；主要供测试与设置页展示。
  Future<int> sizeBytes() async => (await _load()).bytes;

  @override
  Future<Uint8List?> get(ImageCacheKey key) async {
    final index = await _load();
    final name = key.digest;
    if (!index.contains(name)) return null;
    final file = index.file(name);
    try {
      final bytes = await file.readAsBytes();
      index.touch(name);
      // 尽力而为：失败不影响读取结果。
      file.setLastModified(_clock()).ignore();
      return bytes;
    } on FileSystemException {
      index.remove(name);
      return null;
    }
  }

  @override
  Future<void> put(ImageCacheKey key, Uint8List bytes) async {
    if (bytes.length > maxBytes) return;
    final index = await _load();
    final name = key.digest;
    final tmp = File(
      '${index.file(name).path}.${_clock().microsecondsSinceEpoch}.tmp',
    );
    try {
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(index.file(name).path);
    } on FileSystemException {
      await _tryDelete(tmp);
      return;
    }
    index.remove(name);
    index.add(name, bytes.length);
    await _evict(index);
  }

  @override
  Future<void> remove(ImageCacheKey key) async {
    final index = await _load();
    final name = key.digest;
    index.remove(name);
    await _tryDelete(index.file(name));
  }

  @override
  Future<void> clear() async {
    final index = await _load();
    for (final name in index.names.toList()) {
      index.remove(name);
      await _tryDelete(index.file(name));
    }
  }

  Future<void> _evict(_DiskIndex index) async {
    while (index.bytes > maxBytes && index.names.isNotEmpty) {
      final oldest = index.names.first;
      index.remove(oldest);
      await _tryDelete(index.file(oldest));
    }
  }

  static Future<void> _tryDelete(File f) async {
    try {
      await f.delete();
    } on FileSystemException {
      // 已不存在或被占用：下次扫描时再处理。
    }
  }
}

class _DiskIndex {
  _DiskIndex(this.dir);

  final Directory dir;

  /// 插入顺序 = LRU 顺序（最旧在前）。
  final _sizes = <String, int>{};
  int bytes = 0;

  Iterable<String> get names => _sizes.keys;
  bool contains(String name) => _sizes.containsKey(name);
  File file(String name) => File('${dir.path}${Platform.pathSeparator}$name');

  void add(String name, int size) {
    _sizes[name] = size;
    bytes += size;
  }

  void remove(String name) {
    final s = _sizes.remove(name);
    if (s != null) bytes -= s;
  }

  void touch(String name) {
    final s = _sizes.remove(name);
    if (s != null) _sizes[name] = s;
  }
}
