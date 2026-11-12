import 'package:drift/drift.dart';

import '../../core/storage/app_database.dart';
import '../library/library_item.dart';

/// 某个条目的最新进度，也是历史列表中的一项。
class ItemProgress {
  const ItemProgress({
    required this.item,
    required this.unitId,
    required this.unitTitle,
    required this.updatedAt,
    this.page,
    this.pageCount,
    this.position,
  });

  final LibraryItem item;

  /// 最近阅读的 `Unit.id`。
  final String unitId;
  final String unitTitle;

  /// 漫画页码，从 0 开始。
  final int? page;

  /// 该 unit 的总页数（记录时已知才有）。
  final int? pageCount;

  /// 小说 / 视频 / 音乐的位置（字符偏移或毫秒），由对应阅读器 / 播放器定义。
  final int? position;

  /// 最后一次记录进度的时间，即“最近阅读时间”。
  final DateTime updatedAt;

  String get sourceId => item.sourceId;
  String get itemId => item.itemId;
}

/// 某个 unit 的进度与已读标记。
class UnitProgress {
  const UnitProgress({
    required this.unitId,
    required this.read,
    required this.updatedAt,
    this.page,
    this.pageCount,
    this.position,
  });

  final String unitId;
  final int? page;
  final int? pageCount;
  final int? position;
  final bool read;
  final DateTime updatedAt;
}

/// 阅读进度与历史（表 `item_progress_entries` + `unit_progress_entries`）。
///
/// - 每个条目只保留**最新**进度（最后一次 [recordProgress] 的 unit 与页码）；
///   历史即按最近阅读时间倒序的条目进度，不单独建表。
/// - 每个 unit 另有一行：该 unit 内的进度与已读标记，供详情页标记已读章节、
///   重新打开非最新章节时恢复页码。
class HistoryRepository {
  HistoryRepository(this._db, {DateTime Function()? clock})
    : _now = clock ?? DateTime.now;

  final AppDatabase _db;
  final DateTime Function() _now;

  $ItemProgressEntriesTable get _items => _db.itemProgressEntries;
  $UnitProgressEntriesTable get _units => _db.unitProgressEntries;

  /// 记录阅读进度：更新条目的最新进度（即历史）以及该 unit 的进度。
  ///
  /// - [item] 提供历史中展示的标题 / 封面快照（每次覆盖为最新值）。
  /// - [page] 为漫画页码（从 0 开始），[pageCount] 为该 unit 的总页数；
  ///   小说 / 视频等改用 [position]。
  /// - unit 的已读标记：[markRead] 为 true，或 `page` 到达最后一页
  ///   （`page >= pageCount - 1`）时置为已读；已读标记一旦设置不会被后续进度清除，
  ///   取消需调用 [setUnitRead]。
  ///
  /// 阅读器在翻页时调用即可（建议节流，例如停留超过 1 秒或离开页面时）。
  Future<void> recordProgress(
    LibraryItem item, {
    required String unitId,
    required String unitTitle,
    int? page,
    int? pageCount,
    int? position,
    bool markRead = false,
  }) {
    final now = _now();
    final reachedEnd =
        page != null &&
        pageCount != null &&
        pageCount > 0 &&
        page >= pageCount - 1;
    final read = markRead || reachedEnd;
    return _db.transaction(() async {
      await _db
          .into(_items)
          .insertOnConflictUpdate(
            ItemProgressEntriesCompanion.insert(
              sourceId: item.sourceId,
              itemId: item.itemId,
              title: item.title,
              cover: Value(item.cover),
              coverHeaders: Value(item.coverHeaders),
              mediaType: item.mediaType.name,
              unitId: unitId,
              unitTitle: unitTitle,
              page: Value(page),
              pageCount: Value(pageCount),
              position: Value(position),
              updatedAt: now,
            ),
          );
      await _db
          .into(_units)
          .insert(
            UnitProgressEntriesCompanion.insert(
              sourceId: item.sourceId,
              itemId: item.itemId,
              unitId: unitId,
              page: Value(page),
              pageCount: Value(pageCount),
              position: Value(position),
              read: Value(read),
              updatedAt: now,
            ),
            onConflict: DoUpdate(
              (old) => UnitProgressEntriesCompanion.custom(
                page: Variable<int>(page),
                pageCount: Variable<int>(pageCount),
                position: Variable<int>(position),
                read: read ? const Constant(true) : old.read,
                updatedAt: Variable<DateTime>(now),
              ),
            ),
          );
    });
  }

  /// 条目的最新进度；没有读过返回 null。
  Future<ItemProgress?> latestProgress(String sourceId, String itemId) async {
    final row = await _itemQuery(sourceId, itemId).getSingleOrNull();
    return row == null ? null : _toProgress(row);
  }

  /// [latestProgress] 的 stream 版本（详情页“继续阅读”按钮）。
  Stream<ItemProgress?> watchLatestProgress(String sourceId, String itemId) =>
      _itemQuery(
        sourceId,
        itemId,
      ).watchSingleOrNull().map((r) => r == null ? null : _toProgress(r));

  /// 某个 unit 的进度；从未打开过返回 null。
  Future<UnitProgress?> unitProgress(
    String sourceId,
    String itemId,
    String unitId,
  ) async {
    final row = await _unitQuery(sourceId, itemId, unitId).getSingleOrNull();
    return row == null ? null : _toUnit(row);
  }

  /// 某个 unit 是否已读。
  Future<bool> isUnitRead(
    String sourceId,
    String itemId,
    String unitId,
  ) async => (await unitProgress(sourceId, itemId, unitId))?.read ?? false;

  /// 条目下已读 unit 的 id 集合（详情页章节列表置灰）。
  Stream<Set<String>> watchReadUnitIds(String sourceId, String itemId) =>
      (_db.select(_units)..where(
            (t) =>
                t.sourceId.equals(sourceId) &
                t.itemId.equals(itemId) &
                t.read.equals(true),
          ))
          .watch()
          .map((rows) => {for (final r in rows) r.unitId});

  /// 手动标记 / 取消标记某个 unit 已读，不改变条目的最新进度与历史。
  Future<void> setUnitRead(
    String sourceId,
    String itemId,
    String unitId, {
    required bool read,
  }) {
    final now = _now();
    return _db
        .into(_units)
        .insert(
          UnitProgressEntriesCompanion.insert(
            sourceId: sourceId,
            itemId: itemId,
            unitId: unitId,
            read: Value(read),
            updatedAt: now,
          ),
          onConflict: DoUpdate(
            (_) => UnitProgressEntriesCompanion(
              read: Value(read),
              updatedAt: Value(now),
            ),
          ),
        );
  }

  /// 最近阅读的条目，按最近阅读时间倒序。[limit] 为 null 时不限条数。
  Stream<List<ItemProgress>> watchHistory({int? limit}) {
    final q = _db.select(_items)
      ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)]);
    if (limit != null) q.limit(limit);
    return q.watch().map((rows) => [for (final r in rows) ?_toProgress(r)]);
  }

  /// 从历史中删除一个条目（删除其最新进度）。
  ///
  /// 默认同时清除该条目所有 unit 的进度与已读标记；[keepUnitProgress] 为 true 时保留。
  /// 不影响书架。
  Future<void> removeHistory(
    String sourceId,
    String itemId, {
    bool keepUnitProgress = false,
  }) => _db.transaction(() async {
    await (_db.delete(_items)
          ..where((t) => t.sourceId.equals(sourceId) & t.itemId.equals(itemId)))
        .go();
    if (!keepUnitProgress) {
      await (_db.delete(_units)..where(
            (t) => t.sourceId.equals(sourceId) & t.itemId.equals(itemId),
          ))
          .go();
    }
  });

  /// 清空全部历史与进度。
  Future<void> clearHistory() => _db.transaction(() async {
    await _db.delete(_items).go();
    await _db.delete(_units).go();
  });

  SimpleSelectStatement<$ItemProgressEntriesTable, ItemProgressRow> _itemQuery(
    String sourceId,
    String itemId,
  ) =>
      _db.select(_items)
        ..where((t) => t.sourceId.equals(sourceId) & t.itemId.equals(itemId));

  SimpleSelectStatement<$UnitProgressEntriesTable, UnitProgressRow> _unitQuery(
    String sourceId,
    String itemId,
    String unitId,
  ) => _db.select(_units)
    ..where(
      (t) =>
          t.sourceId.equals(sourceId) &
          t.itemId.equals(itemId) &
          t.unitId.equals(unitId),
    );

  static ItemProgress? _toProgress(ItemProgressRow r) {
    final type = parseMediaType(r.mediaType);
    if (type == null) return null;
    return ItemProgress(
      item: LibraryItem(
        sourceId: r.sourceId,
        itemId: r.itemId,
        title: r.title,
        mediaType: type,
        cover: r.cover,
        coverHeaders: r.coverHeaders,
      ),
      unitId: r.unitId,
      unitTitle: r.unitTitle,
      page: r.page,
      pageCount: r.pageCount,
      position: r.position,
      updatedAt: r.updatedAt,
    );
  }

  static UnitProgress _toUnit(UnitProgressRow r) => UnitProgress(
    unitId: r.unitId,
    page: r.page,
    pageCount: r.pageCount,
    position: r.position,
    read: r.read,
    updatedAt: r.updatedAt,
  );
}
