import 'package:drift/drift.dart';

import 'app_database.dart';

/// 按源隔离的持久化 KV（脚本宿主 API `tsumugi.storage`，docs/source-spec.md §4.2）。
///
/// 值以 JSON 文本保存；编码 / 解码由调用方（脚本宿主）负责。
/// 所有方法都以 [sourceId] 为作用域，一个源无法读写另一个源的数据。
///
/// 用量单位为 **Unicode 码点**（键 + 值），与 SQLite 的 `length()` 一致，见 [codePoints]。
abstract interface class SourceStorage {
  Future<String?> read(String sourceId, String key);

  /// 写入一个键。“计算用量 → 检查 [quota] → 写入”是原子的：并发写入（包括同一源的
  /// 多个实例）不会共同超出配额。超出 [quota] 时不写入并返回 false。
  ///
  /// [isCancelled] 在原子区间开始时检查，为 true 时不写入并返回 false
  /// （用于丢弃已结束的脚本调用排队中的写操作）。
  Future<bool> write(
    String sourceId,
    String key,
    String json, {
    int? quota,
    bool Function()? isCancelled,
  });

  /// [isCancelled] 语义同 [write]；返回是否执行了删除。
  Future<bool> delete(
    String sourceId,
    String key, {
    bool Function()? isCancelled,
  });

  /// 该源已用的总码点数（键 + 值）。
  Future<int> usage(String sourceId);

  /// 删除该源的全部数据（卸载源时调用）。
  Future<void> clear(String sourceId);
}

/// 存储用量的计量单位：Unicode 码点数。
int codePoints(String s) => s.runes.length;

/// 基于 [AppDatabase] 的实现（表 `source_storage_entries`）。
///
/// 原子性依赖 drift 事务：同一数据库连接上的事务串行执行。
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
  Future<bool> write(
    String sourceId,
    String key,
    String json, {
    int? quota,
    bool Function()? isCancelled,
  }) => _db.transaction(() async {
    if (isCancelled?.call() ?? false) return false;
    if (quota != null) {
      final old = await read(sourceId, key);
      final next =
          await usage(sourceId) -
          (old == null ? 0 : codePoints(key) + codePoints(old)) +
          codePoints(key) +
          codePoints(json);
      if (next > quota) return false;
    }
    await _db
        .into(_t)
        .insertOnConflictUpdate(
          SourceStorageEntriesCompanion.insert(
            sourceId: sourceId,
            key: key,
            value: json,
          ),
        );
    return true;
  });

  @override
  Future<bool> delete(
    String sourceId,
    String key, {
    bool Function()? isCancelled,
  }) => _db.transaction(() async {
    if (isCancelled?.call() ?? false) return false;
    await (_db.delete(
      _t,
    )..where((t) => t.sourceId.equals(sourceId) & t.key.equals(key))).go();
    return true;
  });

  @override
  Future<int> usage(String sourceId) async {
    // SQLite 的 length(TEXT) 按码点计数（值中不含 NUL：JSON 会转义，键由宿主拒绝 NUL）。
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

/// 内存实现，供测试与无数据库场景使用。各操作在单个同步区间内完成，因此是原子的。
class MemorySourceStorage implements SourceStorage {
  final _data = <String, Map<String, String>>{};

  @override
  Future<String?> read(String sourceId, String key) async =>
      _data[sourceId]?[key];

  @override
  Future<bool> write(
    String sourceId,
    String key,
    String json, {
    int? quota,
    bool Function()? isCancelled,
  }) async {
    if (isCancelled?.call() ?? false) return false;
    final map = _data[sourceId] ??= {};
    if (quota != null) {
      final old = map[key];
      final next =
          _usage(map) -
          (old == null ? 0 : codePoints(key) + codePoints(old)) +
          codePoints(key) +
          codePoints(json);
      if (next > quota) return false;
    }
    map[key] = json;
    return true;
  }

  @override
  Future<bool> delete(
    String sourceId,
    String key, {
    bool Function()? isCancelled,
  }) async {
    if (isCancelled?.call() ?? false) return false;
    _data[sourceId]?.remove(key);
    return true;
  }

  @override
  Future<int> usage(String sourceId) async => _usage(_data[sourceId] ?? {});

  static int _usage(Map<String, String> map) => map.entries.fold(
    0,
    (a, e) => a + codePoints(e.key) + codePoints(e.value),
  );

  @override
  Future<void> clear(String sourceId) async => _data.remove(sourceId);
}
