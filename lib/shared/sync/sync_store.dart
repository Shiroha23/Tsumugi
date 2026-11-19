import 'dart:convert';
import 'dart:math';

import 'package:drift/drift.dart';

import '../../core/storage/app_database.dart';
import '../../sources/model/source_settings.dart';
import '../../sources/registry/installed_source.dart';
import '../../sources/registry/manifest_import.dart';
import '../../sources/registry/source_registry.dart';
import 'sync_document.dart';
import 'sync_merge.dart';
import 'sync_records.dart';

/// 单个源清单的上限（与本地文件导入相同）。
const maxSyncedManifestBytes = 4 * 1024 * 1024;

/// SQLite 中的当前 UTC 毫秒，与 `sync_triggers.drift` 中的表达式一致。
const _sqlNow = "CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)";

/// 经同步安装的源的来源标签。
const syncOriginLabel = 'WebDAV 同步';

/// 同步来的、等待用户确认安装的源（architecture §4.6）。
final class PendingSource {
  const PendingSource({
    required this.id,
    required this.name,
    required this.version,
    required this.manifest,
    required this.enabled,
    required this.sortOrder,
    required this.settings,
    required this.originKind,
    required this.originUrl,
    required this.modifiedAt,
    required this.isUpdate,
    this.dismissed = false,
  });

  final String id;
  final String name;
  final String version;

  /// 清单原文。
  final String manifest;
  final bool enabled;
  final int sortOrder;
  final Map<String, Object?> settings;
  final String originKind;
  final String? originUrl;

  /// 远端记录的 `modifiedAt`。
  final int modifiedAt;

  /// 本机已装同 id 的源（清单不同）。
  final bool isUpdate;

  /// 用户选择了忽略：远端记录变化（[modifiedAt] 不同）前不再显示。
  final bool dismissed;

  /// 安装时记的来源：一律为本地来源“WebDAV 同步”。同步文件中的 [originKind] / [originUrl] 是远端声称的，
  /// 没有经过验证（例如没有按仓库索引校验 sha256），只作展示，不据此把源记为来自某个仓库。
  SourceOrigin get origin => const SourceOrigin.local(syncOriginLabel);

  PendingSource copyWith({bool? dismissed}) => PendingSource(
    id: id,
    name: name,
    version: version,
    manifest: manifest,
    enabled: enabled,
    sortOrder: sortOrder,
    settings: settings,
    originKind: originKind,
    originUrl: originUrl,
    modifiedAt: modifiedAt,
    isUpdate: isUpdate,
    dismissed: dismissed ?? this.dismissed,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'version': version,
    'manifest': manifest,
    'enabled': enabled,
    'sortOrder': sortOrder,
    'settings': settings,
    'originKind': originKind,
    'originUrl': originUrl,
    'modifiedAt': modifiedAt,
    'isUpdate': isUpdate,
    'dismissed': dismissed,
  };

  static PendingSource? tryParse(Object? json) {
    if (json is! Map<String, Object?>) return null;
    try {
      final d = RecordData(json);
      return PendingSource(
        id: d.str('id'),
        name: d.str('name'),
        version: d.str('version'),
        manifest: d.str('manifest'),
        enabled: d.boolean('enabled'),
        sortOrder: d.integer('sortOrder'),
        settings: d.objectOrNull('settings') ?? const {},
        originKind: d.str('originKind'),
        originUrl: d.strOrNull('originUrl'),
        modifiedAt: d.integer('modifiedAt'),
        isUpdate: d.boolean('isUpdate'),
        dismissed: d.boolean('dismissed'),
      );
    } on InvalidRecordData {
      return null;
    }
  }
}

List<PendingSource> decodePendingSources(String? json) {
  if (json == null) return const [];
  try {
    final list = jsonDecode(json);
    if (list is! List) return const [];
    return [for (final e in list) ?PendingSource.tryParse(e)];
  } on FormatException {
    return const [];
  }
}

/// 给界面看的同步状态（不含远端缓存等内部字段）。
final class SyncStatus {
  const SyncStatus({
    this.enabled = false,
    this.serverUrl,
    this.username,
    this.remoteDir,
    this.lastSyncAt,
    this.lastAttemptAt,
    this.lastError,
    this.conditionalUnsupported = false,
    this.pending = const [],
  });

  factory SyncStatus.fromRow(SyncStateRow? row) => row == null
      ? const SyncStatus()
      : SyncStatus(
          enabled: row.enabled,
          serverUrl: row.serverUrl,
          username: row.username,
          remoteDir: row.remoteDir,
          lastSyncAt: row.lastSyncAt,
          lastAttemptAt: row.lastAttemptAt,
          lastError: row.lastError,
          conditionalUnsupported: row.conditionalUnsupported,
          pending: decodePendingSources(row.pendingSourcesJson),
        );

  final bool enabled;
  final String? serverUrl;
  final String? username;
  final String? remoteDir;

  /// 上次成功同步（UTC 毫秒）。
  final int? lastSyncAt;
  final int? lastAttemptAt;

  /// 最近一次同步的错误；null 为成功或尚未同步。
  final String? lastError;
  final bool conditionalUnsupported;

  /// 待安装的源（含已忽略的）。
  final List<PendingSource> pending;

  bool get configured => serverUrl != null && username != null;
}

/// 一次合并写回的结果。
final class AppliedMerge {
  const AppliedMerge({
    required this.result,
    required this.snapshotAt,
    required this.pending,
  });

  final MergeResult result;

  /// 读本地快照时的 SQLite 时钟（UTC 毫秒）。
  final int snapshotAt;

  final List<PendingSource> pending;
}

/// 同步的数据库侧：本机状态、本地快照、把合并结果写回本地（architecture §4.6）。
class SyncStore {
  SyncStore(this._db, {Random? random}) : _random = random ?? Random.secure();

  final AppDatabase _db;
  final Random _random;

  $SyncStateTable get _state => _db.syncState;

  Future<int> sqlNow() async =>
      (await _db.customSelect('SELECT $_sqlNow AS now').getSingle()).read<int>(
        'now',
      );

  /// 本机状态行；不存在时创建（生成随机 `deviceId`）。
  Future<SyncStateRow> ensureState() async {
    final row = await (_db.select(
      _state,
    )..where((t) => t.id.equals(1))).getSingleOrNull();
    if (row != null) return row;
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    final deviceId = bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    await _db
        .into(_state)
        .insert(
          SyncStateCompanion.insert(id: const Value(1), deviceId: deviceId),
          mode: InsertMode.insertOrIgnore,
        );
    return (await (_db.select(
      _state,
    )..where((t) => t.id.equals(1))).getSingle());
  }

  Stream<SyncStatus> watchStatus() => (_db.select(
    _state,
  )..where((t) => t.id.equals(1))).watchSingleOrNull().map(SyncStatus.fromRow);

  Future<void> _update(SyncStateCompanion values) async {
    await ensureState();
    await (_db.update(_state)..where((t) => t.id.equals(1))).write(values);
  }

  /// 保存服务器配置。地址、用户名或目录变化时按从未同步处理：清空上次同步时间、远端缓存、待安装列表与墓碑。
  Future<void> saveConfig({
    required String? serverUrl,
    required String? username,
    required String? remoteDir,
    bool? enabled,
  }) => _db.transaction(() async {
    final old = await ensureState();
    final changed =
        old.serverUrl != serverUrl ||
        old.username != username ||
        old.remoteDir != remoteDir;
    await _update(
      SyncStateCompanion(
        serverUrl: Value(serverUrl),
        username: Value(username),
        remoteDir: Value(remoteDir),
        enabled: enabled == null ? const Value.absent() : Value(enabled),
        lastSyncAt: changed ? const Value(null) : const Value.absent(),
        remoteEtag: changed ? const Value(null) : const Value.absent(),
        remoteSnapshot: changed ? const Value(null) : const Value.absent(),
        conditionalUnsupported: changed
            ? const Value(false)
            : const Value.absent(),
        lastError: changed ? const Value(null) : const Value.absent(),
        lastAttemptAt: changed ? const Value(null) : const Value.absent(),
        pendingSourcesJson: changed ? const Value(null) : const Value.absent(),
      ),
    );
    if (changed) await _db.delete(_db.syncTombstones).go();
  });

  Future<void> setEnabled(bool enabled) =>
      _update(SyncStateCompanion(enabled: Value(enabled)));

  Future<void> recordSuccess({
    required int lastSyncAt,
    required String? etag,
    required Uint8List? snapshot,
    required bool conditionalUnsupported,
    required int attemptAt,
  }) => _update(
    SyncStateCompanion(
      lastSyncAt: Value(lastSyncAt),
      remoteEtag: Value(etag),
      remoteSnapshot: Value(etag == null ? null : snapshot),
      conditionalUnsupported: Value(conditionalUnsupported),
      lastAttemptAt: Value(attemptAt),
      lastError: const Value(null),
    ),
  );

  Future<void> recordFailure(String message, {required int attemptAt}) =>
      _update(
        SyncStateCompanion(
          lastAttemptAt: Value(attemptAt),
          lastError: Value(message),
        ),
      );

  /// 上次成功同步之后本地是否有改动（含删除）。从未同步时恒为 true。
  Future<bool> hasLocalChanges() async {
    final state = await ensureState();
    final since = state.lastSyncAt;
    if (since == null) return true;
    final row = await _db
        .customSelect(
          'SELECT EXISTS (SELECT 1 FROM library_entries WHERE modified_at > ?1) '
          'OR EXISTS (SELECT 1 FROM item_progress_entries WHERE modified_at > ?1) '
          'OR EXISTS (SELECT 1 FROM unit_progress_entries WHERE modified_at > ?1) '
          'OR EXISTS (SELECT 1 FROM installed_sources WHERE modified_at > ?1) '
          'OR EXISTS (SELECT 1 FROM source_repositories WHERE modified_at > ?1) '
          'OR EXISTS (SELECT 1 FROM sync_tombstones WHERE deleted_at > ?1) AS dirty',
          variables: [Variable.withInt(since)],
        )
        .getSingle();
    return row.read<bool>('dirty');
  }

  /// 本地全部记录（含墓碑），`deviceId` 一律为本机。
  Future<Map<String, Map<String, SyncRecord>>> readLocal(
    String deviceId,
  ) async {
    final out = <String, Map<String, SyncRecord>>{
      for (final c in SyncCollections.keyLengths.keys) c: {},
    };
    void add(String c, SyncRecord r) {
      final old = out[c]![r.keyString];
      if (old == null || r.modifiedAt > old.modifiedAt) {
        out[c]![r.keyString] = r;
      }
    }

    for (final r in await _db.select(_db.libraryEntries).get()) {
      add(SyncCollections.library, RowRecords.library(r, deviceId));
    }
    for (final r in await _db.select(_db.itemProgressEntries).get()) {
      add(SyncCollections.itemProgress, RowRecords.itemProgress(r, deviceId));
    }
    for (final r in await _db.select(_db.unitProgressEntries).get()) {
      add(SyncCollections.unitProgress, RowRecords.unitProgress(r, deviceId));
    }
    for (final r in await _db.select(_db.installedSources).get()) {
      add(SyncCollections.sources, RowRecords.source(r, deviceId));
    }
    for (final r in await _db.select(_db.sourceRepositories).get()) {
      add(SyncCollections.repositories, RowRecords.repository(r, deviceId));
    }
    for (final t in await _db.select(_db.syncTombstones).get()) {
      final len = SyncCollections.keyLengths[t.collection];
      if (len == null) continue;
      add(
        t.collection,
        SyncRecord.tombstone(
          key: [t.key1, t.key2, t.key3].sublist(0, len),
          modifiedAt: t.deletedAt,
          deviceId: deviceId,
        ),
      );
    }
    return out;
  }

  /// 在一个事务中：读本地快照 → 与 [remote] 合并 → 把结果写回本地 → 重算待安装的源。
  ///
  /// [trustAbsence] 为 false（服务器不支持条件写入，远端可能被并发写入覆盖）时，远端没有的本地记录一律保留，
  /// 删除只靠墓碑传播。
  Future<AppliedMerge> mergeAndApply(
    SyncDocument? remote, {
    bool trustAbsence = true,
  }) => _db.transaction(() async {
    final state = await ensureState();
    final now = await sqlNow();
    final local = await readLocal(state.deviceId);
    final result = mergeSync(
      local: local,
      remote: remote,
      // 远端没有文件（被删除或换了目录）时不按删除处理，避免清空本地。
      lastSyncAt: remote == null || !trustAbsence ? null : state.lastSyncAt,
      now: now,
      deviceId: state.deviceId,
      resolve: (c, winner, other) => c == SyncCollections.sources
          ? RowRecords.newerManifest(winner, other)
          : winner,
      sameContent: (c, a, b) => c == SyncCollections.sources
          ? RowRecords.sameSource(a, b)
          : sameData(c, a, b),
    );
    final previous = {
      for (final p in decodePendingSources(state.pendingSourcesJson)) p.id: p,
    };
    final pending = <PendingSource>[];
    await _setApplying(true);
    try {
      for (final change in result.localChanges) {
        final p = await _apply(change, now);
        if (p != null) {
          final old = previous[p.id];
          pending.add(
            old != null && old.modifiedAt == p.modifiedAt && old.dismissed
                ? p.copyWith(dismissed: true)
                : p,
          );
        }
      }
    } finally {
      await _setApplying(false);
    }
    pending.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    await _update(
      SyncStateCompanion(
        pendingSourcesJson: Value(
          pending.isEmpty
              ? null
              : jsonEncode([for (final p in pending) p.toJson()]),
        ),
      ),
    );
    return AppliedMerge(result: result, snapshotAt: now, pending: pending);
  });

  Future<void> _setApplying(bool value) =>
      (_db.update(_state)..where((t) => t.id.equals(1))).write(
        SyncStateCompanion(applying: Value(value)),
      );

  Future<void> _setTombstone(String collection, List<String> key, int at) => _db
      .into(_db.syncTombstones)
      .insertOnConflictUpdate(
        SyncTombstonesCompanion.insert(
          collection: collection,
          key1: key[0],
          key2: Value(key.length > 1 ? key[1] : ''),
          key3: Value(key.length > 2 ? key[2] : ''),
          deletedAt: at,
        ),
      );

  Future<void> _removeTombstone(String collection, List<String> key) =>
      (_db.delete(_db.syncTombstones)..where(
            (t) =>
                t.collection.equals(collection) &
                t.key1.equals(key[0]) &
                t.key2.equals(key.length > 1 ? key[1] : '') &
                t.key3.equals(key.length > 2 ? key[2] : ''),
          ))
          .go();

  /// 把一个主键的合并结果写回本地。已安装源需要用户确认时返回待安装项。
  Future<PendingSource?> _apply(KeyMerge change, int now) async {
    final c = change.collection;
    final winner = change.winner;
    final key = change.key;
    if (c == SyncCollections.sources) return _applySource(change);
    if (winner == null || winner.deleted) {
      await switch (c) {
        SyncCollections.library => RowRecords.deleteLibrary(_db, key),
        SyncCollections.itemProgress => RowRecords.deleteItemProgress(_db, key),
        SyncCollections.repositories => RowRecords.deleteRepository(_db, key),
        _ => RowRecords.deleteUnitProgress(_db, key),
      };
      if (winner == null) {
        await _removeTombstone(c, key);
      } else {
        await _setTombstone(c, key, winner.modifiedAt);
      }
      return null;
    }
    try {
      await switch (c) {
        SyncCollections.library => RowRecords.putLibrary(_db, winner, now),
        SyncCollections.itemProgress => RowRecords.putItemProgress(_db, winner),
        SyncCollections.repositories => RowRecords.putRepository(_db, winner),
        _ => RowRecords.putUnitProgress(_db, winner),
      };
      await _removeTombstone(c, key);
    } on InvalidRecordData {
      // 不合法的远端记录不应用到本地，但仍保留在远端文件中（合并结果）。
    }
    return null;
  }

  Future<PendingSource?> _applySource(KeyMerge change) async {
    final winner = change.winner;
    final id = change.key[0];
    final row = await (_db.select(
      _db.installedSources,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    if (winner == null || winner.deleted) {
      if (row != null) {
        // 走 SourceRegistry.remove（连同脚本存储等一起删除），以后新增的清理项也不会漏。
        await SourceRegistry(_db).remove(id);
      }
      if (winner == null) {
        await _removeTombstone(SyncCollections.sources, change.key);
      } else {
        await _setTombstone(
          SyncCollections.sources,
          change.key,
          winner.modifiedAt,
        );
      }
      return null;
    }
    final String manifest;
    final bool enabled;
    final int sortOrder;
    final Map<String, Object?> settings;
    final String originKind;
    final String? originUrl;
    try {
      final d = RecordData(winner.data!);
      manifest = d.str('manifest');
      enabled = d.boolean('enabled');
      sortOrder = d.integer('sortOrder');
      settings = d.objectOrNull('settings') ?? const {};
      originKind = d.str('originKind');
      originUrl = d.strOrNull('originUrl');
    } on InvalidRecordData {
      return null;
    }
    await _removeTombstone(SyncCollections.sources, change.key);
    final local = row == null ? null : InstalledSource.fromRow(row);
    final sameManifest = local != null && local.manifestJson == manifest;
    if (local != null) {
      // 启用、排序与设置直接合并；设置按本机清单过滤。清单不同时保持本机的 modifiedAt，
      // 下次同步远端仍胜出，等用户确认安装新清单。
      final m = local.manifest;
      final kept = m == null
          ? const <String, Object?>{}
          : sanitizeSettingValues(m, settings);
      await (_db.update(
        _db.installedSources,
      )..where((t) => t.id.equals(id))).write(
        InstalledSourcesCompanion(
          enabled: Value(enabled),
          sortOrder: Value(sortOrder),
          settingsJson: Value(encodeStoredSettings(kept)),
          modifiedAt: sameManifest
              ? Value(winner.modifiedAt)
              : const Value.absent(),
        ),
      );
    }
    if (sameManifest) return null;
    if (utf8.encode(manifest).length > maxSyncedManifestBytes) return null;
    final ParsedManifest parsed;
    try {
      parsed = parseManifest(manifest);
    } on SourceImportException {
      return null;
    }
    if (parsed.manifest.id != id) return null;
    return PendingSource(
      id: id,
      name: parsed.manifest.name,
      version: parsed.manifest.version,
      manifest: manifest,
      enabled: enabled,
      sortOrder: sortOrder,
      settings: settings,
      originKind: originKind,
      originUrl: originUrl,
      modifiedAt: winner.modifiedAt,
      isUpdate: local != null,
    );
  }

  /// 待安装列表中的 [id] 标为忽略 / 取消忽略。
  Future<void> setPendingDismissed(String id, bool dismissed) =>
      _db.transaction(() async {
        final state = await ensureState();
        final list = [
          for (final p in decodePendingSources(state.pendingSourcesJson))
            p.id == id ? p.copyWith(dismissed: dismissed) : p,
        ];
        await _update(
          SyncStateCompanion(
            pendingSourcesJson: Value(
              list.isEmpty
                  ? null
                  : jsonEncode([for (final p in list) p.toJson()]),
            ),
          ),
        );
      });

  /// 用户确认安装 [pending] 后调用：把远端的启用 / 排序 / 设置与 `modifiedAt` 写入本机行，并从待安装列表移除。
  ///
  /// 只在本机清单与 [pending] 相同时写入（安装的正是用户预览过的清单）。
  Future<void> completePendingInstall(PendingSource pending) =>
      _db.transaction(() async {
        final state = await ensureState();
        final row = await (_db.select(
          _db.installedSources,
        )..where((t) => t.id.equals(pending.id))).getSingleOrNull();
        if (row != null && row.manifestJson == pending.manifest) {
          final m = InstalledSource.fromRow(row).manifest;
          final kept = m == null
              ? const <String, Object?>{}
              : sanitizeSettingValues(m, pending.settings);
          await _setApplying(true);
          try {
            await (_db.update(
              _db.installedSources,
            )..where((t) => t.id.equals(pending.id))).write(
              InstalledSourcesCompanion(
                enabled: Value(pending.enabled),
                sortOrder: Value(pending.sortOrder),
                settingsJson: Value(encodeStoredSettings(kept)),
                modifiedAt: Value(pending.modifiedAt),
              ),
            );
          } finally {
            await _setApplying(false);
          }
        }
        final list = [
          for (final p in decodePendingSources(state.pendingSourcesJson))
            if (p.id != pending.id) p,
        ];
        await _update(
          SyncStateCompanion(
            pendingSourcesJson: Value(
              list.isEmpty
                  ? null
                  : jsonEncode([for (final p in list) p.toJson()]),
            ),
          ),
        );
      });
}
