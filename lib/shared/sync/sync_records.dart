import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/storage/app_database.dart';
import '../../sources/registry/version.dart';
import '../../sources/repository/repository_exception.dart';
import '../../sources/repository/repository_index.dart';
import 'sync_document.dart';

/// 远端记录的 `data` 不合法。
class InvalidRecordData implements Exception {
  const InvalidRecordData(this.field);

  final String field;

  @override
  String toString() => 'InvalidRecordData($field)';
}

/// 从记录的 `data` 中按类型取字段；不符时抛出 [InvalidRecordData]。
extension type const RecordData(Map<String, Object?> map) {
  String str(String k) => switch (map[k]) {
    final String v => v,
    _ => throw InvalidRecordData(k),
  };

  String? strOrNull(String k) => switch (map[k]) {
    null => null,
    final String v => v,
    _ => throw InvalidRecordData(k),
  };

  int integer(String k) => switch (map[k]) {
    final int v => v,
    _ => throw InvalidRecordData(k),
  };

  int? intOrNull(String k) => switch (map[k]) {
    null => null,
    final int v => v,
    _ => throw InvalidRecordData(k),
  };

  bool boolean(String k) => switch (map[k]) {
    final bool v => v,
    _ => throw InvalidRecordData(k),
  };

  Map<String, String>? headersOrNull(String k) => switch (map[k]) {
    null => null,
    final Map<String, Object?> m when m.values.every((v) => v is String) =>
      m.cast<String, String>(),
    _ => throw InvalidRecordData(k),
  };

  Map<String, Object?>? objectOrNull(String k) => switch (map[k]) {
    null => null,
    final Map<String, Object?> m => m,
    _ => throw InvalidRecordData(k),
  };
}

int _ms(DateTime t) => t.millisecondsSinceEpoch;

DateTime _time(int ms) => DateTime.fromMillisecondsSinceEpoch(ms);

/// 书架、条目进度、unit 进度三张表与同步记录之间的转换（已安装源另见 `SyncStore`）。
///
/// 写入都在同步的写回事务中进行（`sync_state.applying = 1`），`modified_at` 取远端记录的值。
abstract final class RowRecords {
  // ---- 书架 ----

  /// 书架的 `updatedAt`（元数据刷新时间）不同步：详情页每次打开都会写它。
  static SyncRecord library(LibraryEntryRow r, String deviceId) => SyncRecord(
    key: [r.sourceId, r.itemId],
    modifiedAt: r.modifiedAt,
    deviceId: deviceId,
    data: {
      'title': r.title,
      'cover': r.cover,
      'coverHeaders': r.coverHeaders,
      'mediaType': r.mediaType,
      'category': r.category,
      'sortOrder': r.sortOrder,
      'addedAt': _ms(r.addedAt),
    },
  );

  static Future<void> putLibrary(AppDatabase db, SyncRecord rec, int now) {
    final d = RecordData(rec.data!);
    final title = d.str('title');
    final cover = d.strOrNull('cover');
    final headers = d.headersOrNull('coverHeaders');
    final mediaType = d.str('mediaType');
    final category = d.strOrNull('category');
    final sortOrder = d.integer('sortOrder');
    final addedAt = _time(d.integer('addedAt'));
    return db
        .into(db.libraryEntries)
        .insert(
          LibraryEntriesCompanion.insert(
            sourceId: rec.key[0],
            itemId: rec.key[1],
            title: title,
            cover: Value(cover),
            coverHeaders: Value(headers),
            mediaType: mediaType,
            category: Value(category),
            sortOrder: Value(sortOrder),
            addedAt: addedAt,
            updatedAt: _time(now),
            modifiedAt: Value(rec.modifiedAt),
          ),
          onConflict: DoUpdate(
            (_) => LibraryEntriesCompanion(
              title: Value(title),
              cover: Value(cover),
              coverHeaders: Value(headers),
              mediaType: Value(mediaType),
              category: Value(category),
              sortOrder: Value(sortOrder),
              addedAt: Value(addedAt),
              modifiedAt: Value(rec.modifiedAt),
            ),
          ),
        );
  }

  static Future<void> deleteLibrary(AppDatabase db, List<String> key) =>
      (db.delete(db.libraryEntries)
            ..where((t) => t.sourceId.equals(key[0]) & t.itemId.equals(key[1])))
          .go();

  // ---- 条目进度（历史） ----

  static SyncRecord itemProgress(ItemProgressRow r, String deviceId) =>
      SyncRecord(
        key: [r.sourceId, r.itemId],
        modifiedAt: r.modifiedAt,
        deviceId: deviceId,
        data: {
          'title': r.title,
          'cover': r.cover,
          'coverHeaders': r.coverHeaders,
          'mediaType': r.mediaType,
          'unitId': r.unitId,
          'unitTitle': r.unitTitle,
          'page': r.page,
          'pageCount': r.pageCount,
          'position': r.position,
          'updatedAt': _ms(r.updatedAt),
        },
      );

  static Future<void> putItemProgress(AppDatabase db, SyncRecord rec) {
    final d = RecordData(rec.data!);
    return db
        .into(db.itemProgressEntries)
        .insertOnConflictUpdate(
          ItemProgressEntriesCompanion.insert(
            sourceId: rec.key[0],
            itemId: rec.key[1],
            title: d.str('title'),
            cover: Value(d.strOrNull('cover')),
            coverHeaders: Value(d.headersOrNull('coverHeaders')),
            mediaType: d.str('mediaType'),
            unitId: d.str('unitId'),
            unitTitle: d.str('unitTitle'),
            page: Value(d.intOrNull('page')),
            pageCount: Value(d.intOrNull('pageCount')),
            position: Value(d.intOrNull('position')),
            updatedAt: _time(d.integer('updatedAt')),
            modifiedAt: Value(rec.modifiedAt),
          ),
        );
  }

  static Future<void> deleteItemProgress(AppDatabase db, List<String> key) =>
      (db.delete(db.itemProgressEntries)
            ..where((t) => t.sourceId.equals(key[0]) & t.itemId.equals(key[1])))
          .go();

  // ---- unit 进度 ----

  static SyncRecord unitProgress(UnitProgressRow r, String deviceId) =>
      SyncRecord(
        key: [r.sourceId, r.itemId, r.unitId],
        modifiedAt: r.modifiedAt,
        deviceId: deviceId,
        data: {
          'page': r.page,
          'pageCount': r.pageCount,
          'position': r.position,
          'read': r.read,
          'updatedAt': _ms(r.updatedAt),
        },
      );

  static Future<void> putUnitProgress(AppDatabase db, SyncRecord rec) {
    final d = RecordData(rec.data!);
    return db
        .into(db.unitProgressEntries)
        .insertOnConflictUpdate(
          UnitProgressEntriesCompanion.insert(
            sourceId: rec.key[0],
            itemId: rec.key[1],
            unitId: rec.key[2],
            page: Value(d.intOrNull('page')),
            pageCount: Value(d.intOrNull('pageCount')),
            position: Value(d.intOrNull('position')),
            read: Value(d.boolean('read')),
            updatedAt: _time(d.integer('updatedAt')),
            modifiedAt: Value(rec.modifiedAt),
          ),
        );
  }

  static Future<void> deleteUnitProgress(AppDatabase db, List<String> key) =>
      (db.delete(db.unitProgressEntries)..where(
            (t) =>
                t.sourceId.equals(key[0]) &
                t.itemId.equals(key[1]) &
                t.unitId.equals(key[2]),
          ))
          .go();

  // ---- 仓库订阅 ----

  /// 只同步订阅本身（地址与加入时间）；名称与索引由各设备自己检查更新时取得。
  static SyncRecord repository(SourceRepositoryRow r, String deviceId) =>
      SyncRecord(
        key: [r.url],
        modifiedAt: r.modifiedAt,
        deviceId: deviceId,
        data: {'addedAt': _ms(r.addedAt)},
      );

  /// 写入同步来的订阅。地址必须是规范化后的 https 地址（回环地址除外，是否允许由仓库客户端决定）；
  /// 本机还没有时先以地址作名称、索引为空，下次检查更新时取得（取索引照常经仓库客户端的全部限制）。
  static Future<void> putRepository(AppDatabase db, SyncRecord rec) {
    final url = rec.key[0];
    final Uri normalized;
    try {
      normalized = normalizeRepositoryUrl(url, allowLoopbackHttp: true);
    } on RepositoryException {
      throw const InvalidRecordData('key');
    }
    if (normalized.toString() != url) throw const InvalidRecordData('key');
    final addedAt = _time(RecordData(rec.data!).integer('addedAt'));
    return db
        .into(db.sourceRepositories)
        .insert(
          SourceRepositoriesCompanion.insert(
            url: url,
            name: url,
            addedAt: addedAt,
            indexJson: '',
            indexSha256: '',
            modifiedAt: Value(rec.modifiedAt),
          ),
          onConflict: DoUpdate(
            (_) => SourceRepositoriesCompanion(
              addedAt: Value(addedAt),
              modifiedAt: Value(rec.modifiedAt),
            ),
          ),
        );
  }

  static Future<void> deleteRepository(AppDatabase db, List<String> key) =>
      (db.delete(
        db.sourceRepositories,
      )..where((t) => t.url.equals(key[0]))).go();

  // ---- 已安装源 ----

  static SyncRecord source(InstalledSourceRow r, String deviceId) => SyncRecord(
    key: [r.id],
    modifiedAt: r.modifiedAt,
    deviceId: deviceId,
    data: {
      'manifest': r.manifestJson,
      'enabled': r.enabled,
      'sortOrder': r.sortOrder,
      'settings': _decodeSettings(r.settingsJson),
      'originKind': r.originKind.name,
      'originUrl': r.originUrl,
    },
  );

  static Map<String, Object?>? _decodeSettings(String? json) {
    if (json == null) return null;
    try {
      final v = jsonDecode(json);
      return v is Map<String, Object?> && v.isNotEmpty ? v : null;
    } on FormatException {
      return null;
    }
  }

  /// 已安装源的清单按版本取高者：启用 / 排序 / 设置仍跟随胜出的记录。避免一台还没更新的设备改了启用状态后，
  /// 用旧清单覆盖远端（其他设备会得到一个无法安装的“降级”）。
  static SyncRecord newerManifest(SyncRecord winner, SyncRecord other) {
    final mine = _manifestVersion(winner);
    final theirs = _manifestVersion(other);
    if (mine == null || theirs == null) return winner;
    if (compareVersions(theirs, mine) <= 0) return winner;
    return winner.copyWith(
      data: {
        ...winner.data!,
        for (final k in const ['manifest', 'originKind', 'originUrl'])
          k: other.data![k],
      },
    );
  }

  static String? _manifestVersion(SyncRecord r) {
    final text = r.data?['manifest'];
    if (text is! String) return null;
    try {
      final json = jsonDecode(text);
      return json is Map && json['version'] is String
          ? json['version'] as String
          : null;
    } on FormatException {
      return null;
    }
  }

  /// 已安装源的“内容是否相同”：只比较清单、启用、排序与设置；来源不参与（不直接合并，见 architecture §4.6）。
  static bool sameSource(SyncRecord a, SyncRecord b) {
    String pick(SyncRecord r) => canonicalJson({
      for (final k in const ['manifest', 'enabled', 'sortOrder', 'settings'])
        k: switch (r.data![k]) {
          final Map<String, Object?> m when m.isEmpty => null,
          final v => v,
        },
    });
    return pick(a) == pick(b);
  }
}
