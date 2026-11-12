import 'package:drift/drift.dart';

import '../../core/storage/app_database.dart';
import '../../sources/model/common.dart';
import 'library_item.dart';

/// 书架中的一个条目。
class LibraryEntry {
  const LibraryEntry({
    required this.item,
    required this.addedAt,
    required this.updatedAt,
    this.category,
    this.sortOrder = 0,
  });

  final LibraryItem item;

  /// 用户自定义分类；null 为默认分类。
  final String? category;

  /// 手动排序值，越小越靠前。
  final int sortOrder;

  final DateTime addedAt;

  /// 元数据最后一次刷新时间。
  final DateTime updatedAt;

  String get sourceId => item.sourceId;
  String get itemId => item.itemId;
}

/// 书架（表 `library_entries`）。条目以 (sourceId, itemId) 唯一。
///
/// 列表顺序：[LibraryEntry.sortOrder] 升序，相同时按 [LibraryEntry.updatedAt] 倒序。
/// 数据库中类型未知（未来版本写入）的行会被跳过。
class LibraryRepository {
  LibraryRepository(this._db, {DateTime Function()? clock})
    : _now = clock ?? DateTime.now;

  final AppDatabase _db;
  final DateTime Function() _now;

  $LibraryEntriesTable get _t => _db.libraryEntries;

  Expression<bool> _key(
    $LibraryEntriesTable t,
    String sourceId,
    String itemId,
  ) => t.sourceId.equals(sourceId) & t.itemId.equals(itemId);

  /// 加入书架。已在书架时只刷新标题 / 封面 / 类型与 `updatedAt`，
  /// 保留加入时间、分类与排序；[category] 非 null 时同时改分类。
  Future<void> add(LibraryItem item, {String? category}) {
    final now = _now();
    return _db
        .into(_t)
        .insert(
          LibraryEntriesCompanion.insert(
            sourceId: item.sourceId,
            itemId: item.itemId,
            title: item.title,
            cover: Value(item.cover),
            coverHeaders: Value(item.coverHeaders),
            mediaType: item.mediaType.name,
            category: Value(category),
            addedAt: now,
            updatedAt: now,
          ),
          onConflict: DoUpdate(
            (_) => LibraryEntriesCompanion(
              title: Value(item.title),
              cover: Value(item.cover),
              coverHeaders: Value(item.coverHeaders),
              mediaType: Value(item.mediaType.name),
              category: category == null
                  ? const Value.absent()
                  : Value(category),
              updatedAt: Value(now),
            ),
          ),
        );
  }

  /// 移出书架。不影响阅读进度与历史。返回是否确有条目被移除。
  Future<bool> remove(String sourceId, String itemId) async =>
      await (_db.delete(_t)..where((t) => _key(t, sourceId, itemId))).go() > 0;

  /// 已在书架时刷新元数据（详情页拿到新标题 / 封面时调用）；不在书架时什么也不做。
  Future<void> updateMetadata(LibraryItem item) =>
      (_db.update(_t)..where((t) => _key(t, item.sourceId, item.itemId))).write(
        LibraryEntriesCompanion(
          title: Value(item.title),
          cover: Value(item.cover),
          coverHeaders: Value(item.coverHeaders),
          updatedAt: Value(_now()),
        ),
      );

  /// 设置分类（null 为默认分类）。
  Future<void> setCategory(String sourceId, String itemId, String? category) =>
      (_db.update(_t)..where((t) => _key(t, sourceId, itemId))).write(
        LibraryEntriesCompanion(category: Value(category)),
      );

  Future<bool> contains(String sourceId, String itemId) async =>
      await _get(sourceId, itemId).getSingleOrNull() != null;

  /// 是否在书架；随加入 / 移出实时更新。供详情页的“加入书架”按钮使用。
  Stream<bool> watchContains(String sourceId, String itemId) => _get(
    sourceId,
    itemId,
  ).watchSingleOrNull().map((r) => r != null).distinct();

  Future<LibraryEntry?> get(String sourceId, String itemId) async {
    final row = await _get(sourceId, itemId).getSingleOrNull();
    return row == null ? null : _toEntry(row);
  }

  /// 书架列表，可按类型与分类过滤（[category] 为 null 表示不按分类过滤）。
  Stream<List<LibraryEntry>> watchEntries({MediaType? type, String? category}) {
    final q = _db.select(_t)
      ..where((t) {
        Expression<bool> e = const Constant(true);
        if (type != null) e = e & t.mediaType.equals(type.name);
        if (category != null) e = e & t.category.equals(category);
        return e;
      })
      ..orderBy([
        (t) => OrderingTerm.asc(t.sortOrder),
        (t) => OrderingTerm.desc(t.updatedAt),
        (t) => OrderingTerm.asc(t.title),
      ]);
    return q.watch().map((rows) => [for (final r in rows) ?_toEntry(r)]);
  }

  SimpleSelectStatement<$LibraryEntriesTable, LibraryEntryRow> _get(
    String sourceId,
    String itemId,
  ) => _db.select(_t)..where((t) => _key(t, sourceId, itemId));

  static LibraryEntry? _toEntry(LibraryEntryRow r) {
    final type = parseMediaType(r.mediaType);
    if (type == null) return null;
    return LibraryEntry(
      item: LibraryItem(
        sourceId: r.sourceId,
        itemId: r.itemId,
        title: r.title,
        mediaType: type,
        cover: r.cover,
        coverHeaders: r.coverHeaders,
      ),
      category: r.category,
      sortOrder: r.sortOrder,
      addedAt: r.addedAt,
      updatedAt: r.updatedAt,
    );
  }
}
