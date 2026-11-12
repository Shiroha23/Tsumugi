import 'package:drift/drift.dart';

import '../../core/storage/app_database.dart';
import '../model/common.dart';
import '../model/manifest.dart';
import 'installed_source.dart';
import 'manifest_import.dart';
import 'version.dart';

/// 导入预览确认后要执行的操作。
enum ImportAction {
  /// 新安装。
  install,

  /// 同 id、更高版本。
  upgrade,

  /// 同 id、同版本但内容不同（覆盖）。
  reinstall,
}

/// 导入前展示给用户的信息；用户确认后交给 [SourceRegistry.install]。
final class ImportPreview {
  const ImportPreview({
    required this.parsed,
    required this.origin,
    this.existing,
  });

  final ParsedManifest parsed;
  final SourceOrigin origin;

  /// 同 id 的已安装源（若有）。
  final InstalledSource? existing;

  SourceManifest get manifest => parsed.manifest;

  /// 源会访问的主机：baseUrl 主机 + allowedHosts。
  List<String> get hosts => manifestHosts(parsed.manifest);

  ImportAction get action {
    final old = existing;
    if (old == null) return ImportAction.install;
    return compareVersions(manifest.version, old.version) > 0
        ? ImportAction.upgrade
        : ImportAction.reinstall;
  }

  /// 给用户看的非致命警告。
  List<String> get warnings => [
    if (parsed.unknownFields.isNotEmpty)
      '清单包含未知字段（将被忽略）：${parsed.unknownFields.join('、')}',
    if (action == ImportAction.reinstall)
      '版本号未变（${manifest.version}），但清单内容不同，将覆盖已安装的源',
  ];
}

/// 已安装源的管理：导入、校验、升级、启用 / 禁用、删除、排序、按类型查询。
///
/// 只管理清单；可运行的 `Source` 实例由 `SourceFactory` 按引擎类型构造（见 source_factory.dart）。
class SourceRegistry {
  SourceRegistry(this._db, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final AppDatabase _db;
  final DateTime Function() _clock;

  $InstalledSourcesTable get _t => _db.installedSources;

  SimpleSelectStatement<$InstalledSourcesTable, InstalledSourceRow> _query({
    MediaType? type,
    bool? enabled,
  }) {
    final q = _db.select(_t);
    if (type != null) q.where((t) => t.type.equals(type.name));
    if (enabled != null) q.where((t) => t.enabled.equals(enabled));
    return q..orderBy([
      (t) => OrderingTerm.asc(t.sortOrder),
      (t) => OrderingTerm.asc(t.id),
    ]);
  }

  /// 按排序返回已安装源；可按类型 / 启用状态过滤。
  Future<List<InstalledSource>> getAll({
    MediaType? type,
    bool? enabled,
  }) async => (await _query(
    type: type,
    enabled: enabled,
  ).get()).map(InstalledSource.fromRow).toList();

  Stream<List<InstalledSource>> watchAll({MediaType? type, bool? enabled}) =>
      _query(
        type: type,
        enabled: enabled,
      ).watch().map((rows) => rows.map(InstalledSource.fromRow).toList());

  /// 已启用且清单可用的源，供搜索等功能使用。
  Future<List<InstalledSource>> enabled({MediaType? type}) async =>
      (await getAll(
        type: type,
        enabled: true,
      )).where((s) => s.isUsable).toList();

  Future<InstalledSource?> get(String id) async {
    final row = await (_db.select(
      _t,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : InstalledSource.fromRow(row);
  }

  /// 解析并校验清单文本，返回预览；不写数据库。
  ///
  /// 失败时抛出 [SourceImportException]：JSON / 字段错误、apiVersion 不支持、
  /// 已安装更高版本（拒绝降级）、已安装完全相同的清单。
  Future<ImportPreview> prepareImport(
    String text, {
    SourceOrigin origin = const SourceOrigin.local(),
  }) => _prepare(parseManifest(text), origin);

  /// 同 [prepareImport]，输入为文件原始字节（sha256 按原始字节计算）。
  Future<ImportPreview> prepareImportBytes(
    List<int> bytes, {
    SourceOrigin origin = const SourceOrigin.local(),
  }) => _prepare(
    parseManifest(decodeManifestBytes(bytes), rawBytes: bytes),
    origin,
  );

  Future<ImportPreview> _prepare(
    ParsedManifest parsed,
    SourceOrigin origin,
  ) async {
    final existing = await get(parsed.manifest.id);
    _checkAgainstExisting(parsed, existing);
    return ImportPreview(parsed: parsed, origin: origin, existing: existing);
  }

  void _checkAgainstExisting(ParsedManifest parsed, InstalledSource? existing) {
    if (existing == null) return;
    final cmp = compareVersions(parsed.manifest.version, existing.version);
    if (cmp < 0) {
      throw SourceImportException.single(
        SourceImportError.downgrade,
        '已安装更高版本的「${existing.name}」（${existing.version}），'
        '不能降级到 ${parsed.manifest.version}。如需降级，请先删除已安装的源。',
      );
    }
    if (cmp == 0 && parsed.sha256 == existing.manifestSha256) {
      throw SourceImportException.single(
        SourceImportError.alreadyInstalled,
        '「${existing.name}」${existing.version} 已安装',
      );
    }
  }

  /// 安装或更新。更新时保留启用状态、排序与安装时间。
  Future<InstalledSource> install(ImportPreview preview) {
    final parsed = preview.parsed;
    final m = parsed.manifest;
    return _db.transaction(() async {
      // 预览之后数据库可能已变化，重新检查。
      final existing = await get(m.id);
      _checkAgainstExisting(parsed, existing);
      final now = _clock();
      final common = InstalledSourcesCompanion(
        name: Value(m.name),
        type: Value(m.type.name),
        version: Value(m.version),
        apiVersion: Value(m.apiVersion),
        updatedAt: Value(now),
        originKind: Value(preview.origin.kind),
        originUrl: Value(preview.origin.label),
        manifestSha256: Value(parsed.sha256),
        manifestJson: Value(parsed.manifestJson),
      );
      if (existing == null) {
        await _db
            .into(_t)
            .insert(
              common.copyWith(
                id: Value(m.id),
                enabled: const Value(true),
                sortOrder: Value(await _nextSortOrder()),
                installedAt: Value(now),
              ),
            );
      } else {
        await (_db.update(_t)..where((t) => t.id.equals(m.id))).write(common);
      }
      return (await get(m.id))!;
    });
  }

  /// [prepareImport] + [install]，不经过用户确认。
  Future<InstalledSource> importText(
    String text, {
    SourceOrigin origin = const SourceOrigin.local(),
  }) async => install(await prepareImport(text, origin: origin));

  Future<int> _nextSortOrder() async {
    final max = _t.sortOrder.max();
    final row = await (_db.selectOnly(_t)..addColumns([max])).getSingle();
    return (row.read(max) ?? -1) + 1;
  }

  Future<void> setEnabled(String id, bool enabled) async {
    await (_db.update(_t)..where((t) => t.id.equals(id))).write(
      InstalledSourcesCompanion(enabled: Value(enabled)),
    );
  }

  /// 删除；返回是否确有删除。
  Future<bool> remove(String id) async =>
      await (_db.delete(_t)..where((t) => t.id.equals(id))).go() > 0;

  /// 按 [ids] 的顺序重排这些源。
  ///
  /// 只在这些源原有的排序值之间重新分配，不影响其它源（例如其它类型分组）的相对位置。
  /// 不存在的 id 会被忽略。
  Future<void> reorder(List<String> ids) => _db.transaction(() async {
    final rows = await (_db.select(_t)..where((t) => t.id.isIn(ids))).get();
    final present = {for (final r in rows) r.id};
    final ordered = [
      for (final id in ids)
        if (present.contains(id)) id,
    ];
    final slots = rows.map((r) => r.sortOrder).toList()..sort();
    for (var i = 0; i < ordered.length; i++) {
      await (_db.update(_t)..where((t) => t.id.equals(ordered[i]))).write(
        InstalledSourcesCompanion(sortOrder: Value(slots[i])),
      );
    }
  });
}
