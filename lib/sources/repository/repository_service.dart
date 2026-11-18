import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';

import '../../core/storage/app_database.dart';
import '../registry/installed_source.dart';
import '../registry/manifest_import.dart';
import '../registry/source_registry.dart';
import '../registry/version.dart';
import 'repository_exception.dart';
import 'repository_http_client.dart';
import 'repository_index.dart';

/// 一个已订阅的仓库。
final class SubscribedRepository {
  const SubscribedRepository({
    required this.url,
    required this.name,
    required this.addedAt,
    this.lastCheckedAt,
    this.lastError,
    this.lastErrorMessage,
    this.index,
  });

  factory SubscribedRepository.fromRow(SourceRepositoryRow row) {
    RepositoryIndex? index;
    try {
      index = parseRepositoryIndex(
        utf8.encode(row.indexJson),
        Uri.parse(row.url),
      );
    } on Object {
      // 缓存的索引无法解析（例如客户端被降级）：仍可退订与刷新。
    }
    return SubscribedRepository(
      url: row.url,
      name: row.name,
      addedAt: row.addedAt,
      lastCheckedAt: row.lastCheckedAt,
      lastError: RepositoryErrorKind.values.asNameMap()[row.lastErrorCode],
      lastErrorMessage: row.lastErrorMessage,
      index: index,
    );
  }

  /// 规范化后的 index.json 地址（主键）。
  final String url;
  final String name;
  final DateTime addedAt;
  final DateTime? lastCheckedAt;

  /// 上次检查失败的原因；null 表示成功或尚未检查。
  final RepositoryErrorKind? lastError;
  final String? lastErrorMessage;

  /// 上次成功取得的索引。
  final RepositoryIndex? index;

  List<RepositoryEntry> get entries => index?.entries ?? const [];
}

/// 仓库条目相对本机已装源的状态。
enum RepositoryEntryState {
  /// 未安装，可安装。
  notInstalled,

  /// 已从本仓库安装，且不低于仓库版本。
  installed,

  /// 已从本仓库安装，仓库有更高版本。
  updateAvailable,

  /// 同 id 的源来自本地导入或其他仓库，本仓库不能安装 / 更新它。
  otherOrigin,

  /// 条目的 apiVersion 不被客户端支持。
  needsClientUpdate,
}

/// [entry] 相对已安装的同 id 源 [installed]（可为 null）的状态。
RepositoryEntryState entryState(
  String repositoryUrl,
  RepositoryEntry entry,
  InstalledSource? installed,
) {
  final fromHere =
      installed != null &&
      installed.origin.kind == SourceOriginKind.repository &&
      installed.origin.repositoryUrl == repositoryUrl;
  if (fromHere && compareVersions(entry.version, installed.version) <= 0) {
    return RepositoryEntryState.installed;
  }
  if (installed != null && !fromHere) return RepositoryEntryState.otherOrigin;
  if (!entry.apiSupported) return RepositoryEntryState.needsClientUpdate;
  return installed == null
      ? RepositoryEntryState.notInstalled
      : RepositoryEntryState.updateAvailable;
}

/// 已安装源在源页面上显示的仓库状态。
sealed class SourceRepositoryStatus {
  const SourceRepositoryStatus();
}

/// 所属仓库有更高版本。
final class SourceUpdateAvailable extends SourceRepositoryStatus {
  const SourceUpdateAvailable(this.repository, this.entry);

  final SubscribedRepository repository;
  final RepositoryEntry entry;
}

/// 所属仓库有更高版本，但需要更新客户端才能安装。
final class SourceUpdateNeedsClient extends SourceRepositoryStatus {
  const SourceUpdateNeedsClient(this.entry);

  final RepositoryEntry entry;
}

/// 所属仓库已退订，不再检查更新。
final class SourceRepositoryRemoved extends SourceRepositoryStatus {
  const SourceRepositoryRemoved();
}

/// 每个来自仓库的已装源的状态（只含有状态的源）。
Map<String, SourceRepositoryStatus> sourceRepositoryStatuses(
  List<InstalledSource> installed,
  List<SubscribedRepository> repositories,
) {
  final byUrl = {for (final r in repositories) r.url: r};
  final out = <String, SourceRepositoryStatus>{};
  for (final s in installed) {
    if (s.origin.kind != SourceOriginKind.repository) continue;
    final repo = byUrl[s.origin.repositoryUrl];
    if (repo == null) {
      out[s.id] = const SourceRepositoryRemoved();
      continue;
    }
    final entry = repo.index?.entry(s.id);
    if (entry == null) continue;
    switch (entryState(repo.url, entry, s)) {
      case RepositoryEntryState.updateAvailable:
        out[s.id] = SourceUpdateAvailable(repo, entry);
      case RepositoryEntryState.needsClientUpdate:
        out[s.id] = SourceUpdateNeedsClient(entry);
      default:
        break;
    }
  }
  return out;
}

/// 规则仓库订阅：添加 / 退订、检查更新、从仓库准备安装预览（architecture §4.4）。
class RepositoryService {
  RepositoryService(
    this._db,
    this._registry,
    this._http, {
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final AppDatabase _db;
  final SourceRegistry _registry;
  final RepositoryHttpClient _http;
  final DateTime Function() _clock;
  Future<void>? _refreshing;

  $SourceRepositoriesTable get _t => _db.sourceRepositories;

  SimpleSelectStatement<$SourceRepositoriesTable, SourceRepositoryRow>
  _query() => _db.select(_t)
    ..orderBy([
      (t) => OrderingTerm.asc(t.addedAt),
      (t) => OrderingTerm.asc(t.url),
    ]);

  Stream<List<SubscribedRepository>> watchAll() => _query().watch().map(
    (rows) => rows.map(SubscribedRepository.fromRow).toList(),
  );

  Future<List<SubscribedRepository>> getAll() async =>
      (await _query().get()).map(SubscribedRepository.fromRow).toList();

  Future<SubscribedRepository?> get(String url) async {
    final row = await (_db.select(
      _t,
    )..where((t) => t.url.equals(url))).getSingleOrNull();
    return row == null ? null : SubscribedRepository.fromRow(row);
  }

  /// 规范化 [input] 并取得、校验索引；不写数据库。已订阅时抛出 [RepositoryErrorKind.alreadySubscribed]。
  Future<RepositoryIndex> fetchIndex(String input) async {
    final url = normalizeRepositoryUrl(input);
    if (await get(url.toString()) != null) {
      throw RepositoryException(
        RepositoryErrorKind.alreadySubscribed,
        '已订阅该仓库：$url',
      );
    }
    return _fetch(url);
  }

  Future<RepositoryIndex> _fetch(Uri url) async {
    final res = await _http.get(
      url,
      maxBytes: RepositoryHttpClient.maxIndexBytes,
    );
    return parseRepositoryIndex(res.bytes, url);
  }

  /// 订阅 [fetchIndex] 取得的索引。
  Future<SubscribedRepository> subscribe(RepositoryIndex index) =>
      _db.transaction(() async {
        final url = index.url.toString();
        if (await get(url) != null) {
          throw RepositoryException(
            RepositoryErrorKind.alreadySubscribed,
            '已订阅该仓库：$url',
          );
        }
        final now = _clock();
        await _db
            .into(_t)
            .insert(
              SourceRepositoriesCompanion.insert(
                url: url,
                name: index.name,
                addedAt: now,
                lastCheckedAt: Value(now),
                indexJson: index.rawJson,
                indexSha256: index.sha256,
              ),
            );
        return (await get(url))!;
      });

  /// 退订：删除仓库记录，已装的源保留（之后显示“仓库已移除”）。
  Future<bool> unsubscribe(String url) async =>
      await (_db.delete(_t)..where((t) => t.url.equals(url))).go() > 0;

  /// 重新取得 [url] 的索引并保存检查结果；返回失败原因（成功为 null）。
  /// 失败时保留上次成功的索引。
  Future<RepositoryException?> refresh(String url) async {
    RepositoryException? error;
    RepositoryIndex? index;
    try {
      index = await _fetch(Uri.parse(url));
    } on RepositoryException catch (e) {
      error = e;
    } on Object catch (e) {
      error = RepositoryException(RepositoryErrorKind.network, '$e');
    }
    await (_db.update(_t)..where((t) => t.url.equals(url))).write(
      SourceRepositoriesCompanion(
        lastCheckedAt: Value(_clock()),
        lastErrorCode: Value(error?.kind.name),
        lastErrorMessage: Value(error?.message),
        name: index == null ? const Value.absent() : Value(index.name),
        indexJson: index == null ? const Value.absent() : Value(index.rawJson),
        indexSha256: index == null ? const Value.absent() : Value(index.sha256),
      ),
    );
    return error;
  }

  /// 依次检查全部仓库（串行，单个失败不影响其他）。已有检查在进行时返回同一个 Future。
  Future<void> refreshAll() => _refreshing ??= () async {
    try {
      for (final repo in await getAll()) {
        await refresh(repo.url);
      }
    } finally {
      _refreshing = null;
    }
  }();

  /// 下载并校验 [entry] 的清单，生成安装 / 更新预览（之后由 [SourceRegistry.install] 安装）。
  ///
  /// 依次检查：apiVersion 受支持 → 同 id 已装源来自本仓库 → 下载（≤ 4 MiB）→ sha256 → 解析与清单校验
  /// （[SourceRegistry.prepareImportBytes]，含拒绝降级）→ 清单 id / version / apiVersion 与条目一致。
  /// 失败时抛出 [RepositoryException] 或 [SourceImportException]。
  Future<ImportPreview> prepareInstall(
    SubscribedRepository repository,
    RepositoryEntry entry,
  ) async {
    if (!entry.apiSupported) {
      throw RepositoryException(
        RepositoryErrorKind.unsupportedApiVersion,
        '「${entry.name}」需要更新版本的客户端（apiVersion ${entry.apiVersion}）',
      );
    }
    final existing = await _registry.get(entry.id);
    if (existing != null &&
        entryState(repository.url, entry, existing) ==
            RepositoryEntryState.otherOrigin) {
      throw RepositoryException(
        RepositoryErrorKind.otherOrigin,
        '已安装的「${existing.name}」来自'
        '${existing.origin.kind == SourceOriginKind.local ? '本地导入' : '其他仓库'}，'
        '不能由这个仓库安装或更新。如需改用这个仓库的版本，请先删除已安装的源。',
      );
    }
    final res = await _http.get(
      entry.url,
      maxBytes: RepositoryHttpClient.maxManifestBytes,
    );
    final hash = sha256.convert(res.bytes).toString();
    if (hash != entry.sha256) {
      throw RepositoryException(
        RepositoryErrorKind.hashMismatch,
        '「${entry.name}」的清单与仓库索引中的 sha256 不符，已拒绝安装',
      );
    }
    final preview = await _registry.prepareImportBytes(
      res.bytes,
      origin: SourceOrigin.repository(
        entry.url.toString(),
        repositoryUrl: repository.url,
      ),
    );
    final m = preview.manifest;
    final mismatched = [
      if (m.id != entry.id) 'id（索引 ${entry.id}，清单 ${m.id}）',
      if (m.version != entry.version)
        'version（索引 ${entry.version}，清单 ${m.version}）',
      if (m.apiVersion != entry.apiVersion)
        'apiVersion（索引 ${entry.apiVersion}，清单 ${m.apiVersion}）',
    ];
    if (mismatched.isNotEmpty) {
      throw RepositoryException(
        RepositoryErrorKind.manifestMismatch,
        '清单与仓库索引不一致：${mismatched.join('、')}，已拒绝安装',
      );
    }
    return preview;
  }
}
