import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/storage/app_database.dart';
import '../../sources/model/common.dart';
import '../library/library_item.dart';

/// unit 的下载状态（`download_units.status`）。
enum DownloadStatus {
  queued,
  running,
  paused,
  failed,
  done;

  static DownloadStatus parse(String name) =>
      values.where((s) => s.name == name).firstOrNull ?? DownloadStatus.failed;
}

/// 暂停原因：源不可用（被删除 / 禁用 / 清单损坏）。不是 source-spec §6 的错误码，只在下载中使用。
const downloadSourceUnavailable = 'E_SOURCE_UNAVAILABLE';

/// 本地文件缺失或损坏，阅读器已回退到网络。
const downloadFilesMissing = 'E_FILES_MISSING';

/// 暂停整个源的错误码：需要用户在验证页完成验证 / 登录，或源不可用。
const sourcePausingErrors = {
  'E_CHALLENGE',
  'E_LOGIN_REQUIRED',
  downloadSourceUnavailable,
};

/// 下载的条目（含快照）。
final class DownloadItem {
  const DownloadItem({
    required this.item,
    required this.detail,
    required this.createdAt,
    required this.updatedAt,
  });

  final LibraryItem item;

  /// 加入下载时的 `Detail`；JSON 无法解析时为 null。
  final Detail? detail;
  final DateTime createdAt;
  final DateTime updatedAt;

  String get sourceId => item.sourceId;
  String get itemId => item.itemId;

  static DownloadItem? fromRow(DownloadItemRow r) {
    final type = parseMediaType(r.mediaType);
    if (type == null) return null;
    Detail? detail;
    try {
      detail = Detail.fromJson(
        jsonDecode(r.detailJson) as Map<String, dynamic>,
      );
    } on Object {
      detail = null;
    }
    return DownloadItem(
      item: LibraryItem(
        sourceId: r.sourceId,
        itemId: r.itemId,
        title: r.title,
        mediaType: type,
        cover: r.cover,
        coverHeaders: r.coverHeaders,
      ),
      detail: detail,
      createdAt: r.createdAt,
      updatedAt: r.updatedAt,
    );
  }
}

/// 一个下载的 unit。
final class DownloadUnit {
  const DownloadUnit({
    required this.sourceId,
    required this.itemId,
    required this.unitId,
    required this.title,
    required this.groupName,
    required this.index,
    required this.status,
    required this.completedFiles,
    required this.totalFiles,
    required this.bytes,
    required this.errorCode,
    required this.queueOrder,
    required this.updatedAt,
  });

  final String sourceId;
  final String itemId;
  final String unitId;
  final String title;
  final String groupName;
  final int index;
  final DownloadStatus status;
  final int completedFiles;
  final int totalFiles;
  final int bytes;
  final String? errorCode;
  final int queueOrder;
  final DateTime updatedAt;

  /// 因验证 / 登录或源不可用而暂停（整个源暂停）。
  bool get pausesSource =>
      status == DownloadStatus.paused &&
      sourcePausingErrors.contains(errorCode);

  factory DownloadUnit.fromRow(DownloadUnitRow r) => DownloadUnit(
    sourceId: r.sourceId,
    itemId: r.itemId,
    unitId: r.unitId,
    title: r.title,
    groupName: r.groupName,
    index: r.unitIndex,
    status: DownloadStatus.parse(r.status),
    completedFiles: r.completedFiles,
    totalFiles: r.totalFiles,
    bytes: r.bytes,
    errorCode: r.errorCode,
    queueOrder: r.queueOrder,
    updatedAt: r.updatedAt,
  );
}

/// 要加入下载的 unit。
final class DownloadRequestUnit {
  const DownloadRequestUnit(
    this.unit, {
    required this.groupName,
    required this.index,
  });

  final Unit unit;
  final String groupName;
  final int index;
}

/// `download_items` / `download_units` 的访问层。
class DownloadRepository {
  DownloadRepository(this._db, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final AppDatabase _db;
  final DateTime Function() _clock;

  $DownloadItemsTable get _items => _db.downloadItems;
  $DownloadUnitsTable get _units => _db.downloadUnits;

  /// 保存条目快照并把 [units] 加入队列：新 unit 为 `queued`；已存在且未完成的回到 `queued`；
  /// 已完成的不变。返回实际加入队列的数量。
  Future<int> enqueue(
    LibraryItem item,
    Detail detail,
    List<DownloadRequestUnit> units,
  ) => _db.transaction(() async {
    final now = _clock();
    final existing =
        await (_db.select(_items)..where(
              (t) =>
                  t.sourceId.equals(item.sourceId) &
                  t.itemId.equals(item.itemId),
            ))
            .getSingleOrNull();
    await _db
        .into(_items)
        .insertOnConflictUpdate(
          DownloadItemsCompanion.insert(
            sourceId: item.sourceId,
            itemId: item.itemId,
            title: item.title,
            cover: Value(item.cover),
            coverHeaders: Value(item.coverHeaders),
            mediaType: item.mediaType.name,
            detailJson: jsonEncode(detail.toJson()),
            createdAt: existing?.createdAt ?? now,
            updatedAt: now,
          ),
        );
    final maxOrder = _units.queueOrder.max();
    var order =
        ((await (_db.selectOnly(_units)..addColumns([maxOrder]))
                .map((r) => r.read(maxOrder))
                .getSingle()) ??
            -1) +
        1;
    var added = 0;
    for (final u in units) {
      final row = await _unitQuery(
        item.sourceId,
        item.itemId,
        u.unit.id,
      ).getSingleOrNull();
      if (row != null &&
          DownloadStatus.parse(row.status) == DownloadStatus.done) {
        continue;
      }
      if (row != null &&
          {
            DownloadStatus.queued,
            DownloadStatus.running,
          }.contains(DownloadStatus.parse(row.status))) {
        continue;
      }
      added++;
      await _db
          .into(_units)
          .insertOnConflictUpdate(
            DownloadUnitsCompanion.insert(
              sourceId: item.sourceId,
              itemId: item.itemId,
              unitId: u.unit.id,
              title: u.unit.title,
              groupName: u.groupName,
              unitIndex: u.index,
              status: DownloadStatus.queued.name,
              completedFiles: Value(row?.completedFiles ?? 0),
              totalFiles: Value(row?.totalFiles ?? 0),
              bytes: Value(row?.bytes ?? 0),
              errorCode: const Value(null),
              queueOrder: order++,
              updatedAt: now,
            ),
          );
    }
    return added;
  });

  SimpleSelectStatement<$DownloadUnitsTable, DownloadUnitRow> _unitQuery(
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

  Future<DownloadItem?> item(String sourceId, String itemId) async {
    final row =
        await (_db.select(_items)..where(
              (t) => t.sourceId.equals(sourceId) & t.itemId.equals(itemId),
            ))
            .getSingleOrNull();
    return row == null ? null : DownloadItem.fromRow(row);
  }

  Future<DownloadUnit?> unit(
    String sourceId,
    String itemId,
    String unitId,
  ) async {
    final row = await _unitQuery(sourceId, itemId, unitId).getSingleOrNull();
    return row == null ? null : DownloadUnit.fromRow(row);
  }

  /// 全部下载条目，最近加入 / 更新的在前。
  Stream<List<DownloadItem>> watchItems() =>
      (_db.select(_items)..orderBy([(t) => OrderingTerm.desc(t.updatedAt)]))
          .watch()
          .map((rows) => [for (final r in rows) ?DownloadItem.fromRow(r)]);

  Stream<DownloadItem?> watchItem(String sourceId, String itemId) =>
      (_db.select(_items)..where(
            (t) => t.sourceId.equals(sourceId) & t.itemId.equals(itemId),
          ))
          .watchSingleOrNull()
          .map((r) => r == null ? null : DownloadItem.fromRow(r));

  /// 某条目的 unit，按线路与下标排序。
  Stream<List<DownloadUnit>> watchUnits(String sourceId, String itemId) =>
      (_db.select(_units)
            ..where(
              (t) => t.sourceId.equals(sourceId) & t.itemId.equals(itemId),
            )
            ..orderBy([
              (t) => OrderingTerm.asc(t.groupName),
              (t) => OrderingTerm.asc(t.unitIndex),
            ]))
          .watch()
          .map((rows) => rows.map(DownloadUnit.fromRow).toList());

  Stream<List<DownloadUnit>> watchAllUnits() => _db
      .select(_units)
      .watch()
      .map((rows) => rows.map(DownloadUnit.fromRow).toList());

  Future<List<DownloadUnit>> allUnits() async =>
      (await _db.select(_units).get()).map(DownloadUnit.fromRow).toList();

  /// 排队中的 unit，按加入顺序。
  Future<List<DownloadUnit>> queued() async =>
      (await (_db.select(_units)
                ..where((t) => t.status.equals(DownloadStatus.queued.name))
                ..orderBy([(t) => OrderingTerm.asc(t.queueOrder)]))
              .get())
          .map(DownloadUnit.fromRow)
          .toList();

  /// 应用启动时：上次进行中的 unit 回到 `queued`（§4.5）。
  Future<void> resetRunning() =>
      (_db.update(
        _units,
      )..where((t) => t.status.equals(DownloadStatus.running.name))).write(
        DownloadUnitsCompanion(
          status: Value(DownloadStatus.queued.name),
          updatedAt: Value(_clock()),
        ),
      );

  /// 改状态；给出 [onlyFrom] 时只在当前状态属于其中时修改。返回修改的行数。
  Future<int> setStatus(
    String sourceId,
    String itemId,
    String unitId,
    DownloadStatus status, {
    String? errorCode,
    int? completedFiles,
    int? totalFiles,
    int? bytes,
    Set<DownloadStatus>? onlyFrom,
  }) =>
      (_db.update(_units)..where((t) {
            var e =
                t.sourceId.equals(sourceId) &
                t.itemId.equals(itemId) &
                t.unitId.equals(unitId);
            if (onlyFrom != null) {
              e = e & t.status.isIn([for (final s in onlyFrom) s.name]);
            }
            return e;
          }))
          .write(
            DownloadUnitsCompanion(
              status: Value(status.name),
              errorCode: Value(errorCode),
              completedFiles: completedFiles == null
                  ? const Value.absent()
                  : Value(completedFiles),
              totalFiles: totalFiles == null
                  ? const Value.absent()
                  : Value(totalFiles),
              bytes: bytes == null ? const Value.absent() : Value(bytes),
              updatedAt: Value(_clock()),
            ),
          );

  /// 把仍为 `queued` 的 unit 改为 `running`；已被暂停 / 删除时返回 false。
  Future<bool> claim(String sourceId, String itemId, String unitId) async =>
      await (_db.update(_units)..where(
            (t) =>
                t.sourceId.equals(sourceId) &
                t.itemId.equals(itemId) &
                t.unitId.equals(unitId) &
                t.status.equals(DownloadStatus.queued.name),
          ))
          .write(
            DownloadUnitsCompanion(
              status: Value(DownloadStatus.running.name),
              errorCode: const Value(null),
              updatedAt: Value(_clock()),
            ),
          ) >
      0;

  /// 只更新进度（不改状态）。
  Future<void> setProgress(
    String sourceId,
    String itemId,
    String unitId, {
    required int completedFiles,
    required int totalFiles,
    required int bytes,
  }) =>
      (_db.update(_units)..where(
            (t) =>
                t.sourceId.equals(sourceId) &
                t.itemId.equals(itemId) &
                t.unitId.equals(unitId),
          ))
          .write(
            DownloadUnitsCompanion(
              completedFiles: Value(completedFiles),
              totalFiles: Value(totalFiles),
              bytes: Value(bytes),
              updatedAt: Value(_clock()),
            ),
          );

  /// 把某源中满足 [where] 的 unit 改为 [to]（例如验证完成后恢复因验证暂停的 unit）。
  Future<int> setSourceStatus(
    String sourceId, {
    required Set<DownloadStatus> from,
    required DownloadStatus to,
    bool onlySourcePausing = false,
  }) =>
      (_db.update(_units)..where((t) {
            var e =
                t.sourceId.equals(sourceId) &
                t.status.isIn([for (final s in from) s.name]);
            if (onlySourcePausing) {
              e = e & t.errorCode.isIn(sourcePausingErrors);
            }
            return e;
          }))
          .write(
            DownloadUnitsCompanion(
              status: Value(to.name),
              errorCode: const Value(null),
              updatedAt: Value(_clock()),
            ),
          );

  Future<void> deleteUnit(String sourceId, String itemId, String unitId) =>
      _db.transaction(() async {
        await _unitDelete(sourceId, itemId, unitId).go();
        await _deleteItemIfEmpty(sourceId, itemId);
      });

  DeleteStatement<$DownloadUnitsTable, DownloadUnitRow> _unitDelete(
    String sourceId,
    String itemId,
    String unitId,
  ) => _db.delete(_units)
    ..where(
      (t) =>
          t.sourceId.equals(sourceId) &
          t.itemId.equals(itemId) &
          t.unitId.equals(unitId),
    );

  Future<void> _deleteItemIfEmpty(String sourceId, String itemId) async {
    final count = _units.unitId.count();
    final n =
        await (_db.selectOnly(_units)
              ..addColumns([count])
              ..where(
                _units.sourceId.equals(sourceId) & _units.itemId.equals(itemId),
              ))
            .map((r) => r.read(count))
            .getSingle() ??
        0;
    if (n == 0) {
      await (_db.delete(_items)..where(
            (t) => t.sourceId.equals(sourceId) & t.itemId.equals(itemId),
          ))
          .go();
    }
  }

  Future<void> deleteItem(
    String sourceId,
    String itemId,
  ) => _db.transaction(() async {
    await (_db.delete(_units)
          ..where((t) => t.sourceId.equals(sourceId) & t.itemId.equals(itemId)))
        .go();
    await (_db.delete(_items)
          ..where((t) => t.sourceId.equals(sourceId) & t.itemId.equals(itemId)))
        .go();
  });

  Future<void> deleteSource(String sourceId) => _db.transaction(() async {
    await (_db.delete(_units)..where((t) => t.sourceId.equals(sourceId))).go();
    await (_db.delete(_items)..where((t) => t.sourceId.equals(sourceId))).go();
  });

  Future<bool> hasSource(String sourceId) async =>
      (await (_db.select(_items)
            ..where((t) => t.sourceId.equals(sourceId))
            ..limit(1))
          .getSingleOrNull()) !=
      null;

  Future<void> deleteAll() => _db.transaction(() async {
    await _db.delete(_units).go();
    await _db.delete(_items).go();
  });
}
