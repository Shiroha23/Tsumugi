import 'package:drift/drift.dart';

import 'app_database.dart';

/// 按源隔离的持久化 KV（脚本宿主 API `tsumugi.storage`，docs/source-spec.md §4.2）。
///
/// 值以 JSON 文本保存；编码 / 解码与大小限制由调用方（脚本宿主）负责。
/// 所有方法都以 [sourceId] 为作用域，一个源无法读写另一个源的数据。
abstract interface class SourceStorage {
  Future<String?> read(String sourceId, String key);

  Future<void> write(String sourceId, String key, String json);

  Future<void> delete(String sourceId, String key);

  /// 该源已用的总字节数（键 + 值的 UTF-16 长度近似）。
  Future<int> usage(String sourceId);

  /// 删除该源的全部数据（卸载源时调用）。
  Future<void> clear(String sourceId);
}

/// 基于 [AppDatabase] 的实现（表 `source_storage_entries`）。
class DriftSourceStorage implements SourceStorage {
  DriftSourceStorage(this._db);

  final AppDatabase _db;

  $SourceStorageEntriesTable get _t => _db.sourceStorageEntries;

  @override
  Future<String?> read(String sourceId, String key) async {
    final row =
        await (_db.select(_t)
              ..where((t) => t.sourceId.equals(sourceId) & t.key.equals(key)))
            .getSingleOrNull();
    return row?.value;
  }

  @override
  Future<void> write(String sourceId, String key, String json) => _db
      .into(_t)
      .insertOnConflictUpdate(
        SourceStorageEntriesCompanion.insert(
          sourceId: sourceId,
          key: key,
          value: json,
        ),
      );

  @override
  Future<void> delete(String sourceId, String key) => (_db.delete(
    _t,
  )..where((t) => t.sourceId.equals(sourceId) & t.key.equals(key))).go();

  @override
  Future<int> usage(String sourceId) async {
    final total = _t.key.length.sum() + _t.value.length.sum();
    final row =
        await (_db.selectOnly(_t)
              ..addColumns([total])
              ..where(_t.sourceId.equals(sourceId)))
            .getSingle();
    return row.read(total) ?? 0;
  }

  @override
  Future<void> clear(String sourceId) =>
      (_db.delete(_t)..where((t) => t.sourceId.equals(sourceId))).go();
}

/// 内存实现，供测试与无数据库场景使用。
class MemorySourceStorage implements SourceStorage {
  final _data = <String, Map<String, String>>{};

  @override
  Future<String?> read(String sourceId, String key) async =>
      _data[sourceId]?[key];

  @override
  Future<void> write(String sourceId, String key, String json) async =>
      (_data[sourceId] ??= {})[key] = json;

  @override
  Future<void> delete(String sourceId, String key) async =>
      _data[sourceId]?.remove(key);

  @override
  Future<int> usage(String sourceId) async => [
    for (final e in (_data[sourceId] ?? const {}).entries)
      e.key.length + e.value.length,
  ].fold<int>(0, (a, b) => a + b);

  @override
  Future<void> clear(String sourceId) async => _data.remove(sourceId);
}
