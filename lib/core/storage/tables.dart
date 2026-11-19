import 'dart:convert';

import 'package:drift/drift.dart';

/// 源的安装来源。
enum SourceOriginKind {
  /// 用户粘贴 / 选择文件 / 剪贴板导入。
  local,

  /// 从规则仓库安装（M6），`originUrl` 为清单 URL。
  repository,
}

/// 已安装的源。清单原文是唯一的事实来源，其余列是为了列表、排序与过滤而冗余的索引字段，
/// 安装 / 更新时与清单同步写入。
@DataClassName('InstalledSourceRow')
class InstalledSources extends Table {
  /// 清单 `id`。
  TextColumn get id => text()();

  TextColumn get name => text()();

  /// `MediaType.name`（comic / novel / video / music）。存字符串而非 drift 枚举，
  /// 以免 `core` 依赖 `sources` 的模型。
  TextColumn get type => text()();

  TextColumn get version => text()();

  IntColumn get apiVersion => integer()();

  BoolColumn get enabled => boolean().withDefault(const Constant(true))();

  /// 全局排序值，越小越靠前；同类型内的相对顺序即列表顺序。
  IntColumn get sortOrder => integer()();

  DateTimeColumn get installedAt => dateTime()();

  /// 最近一次安装 / 更新时间。
  DateTimeColumn get updatedAt => dateTime()();

  TextColumn get originKind => textEnum<SourceOriginKind>()();

  /// `originKind == repository` 时为清单 URL；本地导入时可为文件名或空。
  TextColumn get originUrl => text().nullable()();

  /// 清单原文（UTF-8 字节）的 sha256，小写十六进制。
  TextColumn get manifestSha256 => text()();

  /// 清单 JSON 原文。
  TextColumn get manifestJson => text()();

  /// 用户修改过的源设置（v4，docs/source-spec.md §1.1）：JSON 对象，只含改过的键；null 表示全部取默认。
  TextColumn get settingsJson => text().nullable()();

  /// 所属规则仓库（v5，architecture §4.4）：`originKind == repository` 时为仓库 index.json 的规范化地址。
  /// 仓库被退订后保留原值，用于显示“仓库已移除”。
  TextColumn get repositoryUrl => text().nullable()();

  /// 最后一次参与同步的改动时间（UTC 毫秒，v7，architecture §4.6）。由 `sync_triggers.drift` 中的触发器维护，
  /// 业务代码不写；0 表示升级前已有、从未改动过的行。
  IntColumn get modifiedAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// 订阅的规则仓库（v5，architecture §4.4）。
@DataClassName('SourceRepositoryRow')
class SourceRepositories extends Table {
  /// 规范化后的 index.json 地址。
  TextColumn get url => text()();

  /// 取自索引的 `name`。
  TextColumn get name => text()();

  DateTimeColumn get addedAt => dateTime()();

  /// 上次检查（成功或失败）的时间。
  DateTimeColumn get lastCheckedAt => dateTime().nullable()();

  /// 上次检查的错误码（`RepositoryErrorKind.name`）；null 表示成功或尚未检查。
  TextColumn get lastErrorCode => text().nullable()();

  /// 上次检查的错误说明（中文）。
  TextColumn get lastErrorMessage => text().nullable()();

  /// 上次成功取得的索引原文，离线时仍可浏览。
  TextColumn get indexJson => text()();

  /// [indexJson] 原始字节的 sha256。
  TextColumn get indexSha256 => text()();

  /// 最后一次参与同步的改动时间（UTC 毫秒，v7，architecture §4.6），由触发器维护。只有订阅与退订算改动：
  /// 检查更新时刷新的名称与索引不同步。
  IntColumn get modifiedAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column<Object>> get primaryKey => {url};
}

/// 脚本源的 `tsumugi.storage`（docs/source-spec.md §4.2）：按源隔离的 KV，值为 JSON 文本。
@DataClassName('SourceStorageRow')
class SourceStorageEntries extends Table {
  /// 清单 `id`。
  TextColumn get sourceId => text()();

  TextColumn get key => text()();

  /// JSON 编码后的值。
  TextColumn get value => text()();

  @override
  Set<Column<Object>> get primaryKey => {sourceId, key};
}

/// 字符串到字符串的映射（如封面请求头）以 JSON 对象文本保存。
class StringMapConverter extends TypeConverter<Map<String, String>, String> {
  const StringMapConverter();

  @override
  Map<String, String> fromSql(String fromDb) {
    final decoded = jsonDecode(fromDb);
    if (decoded is! Map) return const {};
    return {
      for (final e in decoded.entries)
        if (e.value is String) '${e.key}': e.value as String,
    };
  }

  @override
  String toSql(Map<String, String> value) => jsonEncode(value);
}

/// 书架条目（v3）。同一 (sourceId, itemId) 只有一条。
///
/// 标题、封面等是加入书架时从 `SearchItem` / `Detail` 拷贝的快照，源失效后书架仍可展示。
@DataClassName('LibraryEntryRow')
class LibraryEntries extends Table {
  /// 清单 `id`。
  TextColumn get sourceId => text()();

  /// `SearchItem.id`。
  TextColumn get itemId => text()();

  TextColumn get title => text()();

  TextColumn get cover => text().nullable()();

  /// 加载封面时需要的请求头。
  TextColumn get coverHeaders =>
      text().map(const StringMapConverter()).nullable()();

  /// `MediaType.name`。
  TextColumn get mediaType => text()();

  /// 用户自定义分类；null 为默认分类。
  TextColumn get category => text().nullable()();

  /// 手动排序值，越小越靠前；相同时按 [updatedAt] 倒序。
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  DateTimeColumn get addedAt => dateTime()();

  /// 条目元数据最后一次刷新时间（加入、更新标题封面等）。
  DateTimeColumn get updatedAt => dateTime()();

  /// 最后一次参与同步的改动时间（UTC 毫秒，v5，architecture §4.6）。由 `sync_triggers.drift` 中的触发器维护，
  /// 业务代码不写；0 表示升级前已有、从未改动过的行。
  IntColumn get modifiedAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column<Object>> get primaryKey => {sourceId, itemId};
}

/// 每个条目的最新阅读进度（v3），同时充当“历史”：历史即按 [updatedAt] 倒序的本表。
///
/// 存一份标题 / 封面快照，使历史不依赖书架（未加入书架的条目也有历史）。
@DataClassName('ItemProgressRow')
@TableIndex(name: 'item_progress_updated_at', columns: {#updatedAt})
class ItemProgressEntries extends Table {
  TextColumn get sourceId => text()();

  TextColumn get itemId => text()();

  TextColumn get title => text()();

  TextColumn get cover => text().nullable()();

  TextColumn get coverHeaders =>
      text().map(const StringMapConverter()).nullable()();

  TextColumn get mediaType => text()();

  /// 最近阅读的 `Unit.id`。
  TextColumn get unitId => text()();

  TextColumn get unitTitle => text()();

  /// 漫画页码（从 0 开始）。
  IntColumn get page => integer().nullable()();

  /// 该 unit 的总页数（已知时）。
  IntColumn get pageCount => integer().nullable()();

  /// 小说 / 视频 / 音乐的位置（字符偏移或毫秒），由对应阅读器 / 播放器定义。
  IntColumn get position => integer().nullable()();

  DateTimeColumn get updatedAt => dateTime()();

  /// 最后一次参与同步的改动时间（UTC 毫秒，v5，architecture §4.6）。由 `sync_triggers.drift` 中的触发器维护，
  /// 业务代码不写；0 表示升级前已有、从未改动过的行。
  IntColumn get modifiedAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column<Object>> get primaryKey => {sourceId, itemId};
}

/// 按 unit 的进度与已读标记（v3）。
@DataClassName('UnitProgressRow')
class UnitProgressEntries extends Table {
  TextColumn get sourceId => text()();

  TextColumn get itemId => text()();

  TextColumn get unitId => text()();

  IntColumn get page => integer().nullable()();

  IntColumn get pageCount => integer().nullable()();

  IntColumn get position => integer().nullable()();

  BoolColumn get read => boolean().withDefault(const Constant(false))();

  DateTimeColumn get updatedAt => dateTime()();

  /// 最后一次参与同步的改动时间（UTC 毫秒，v5，architecture §4.6）。由 `sync_triggers.drift` 中的触发器维护，
  /// 业务代码不写；0 表示升级前已有、从未改动过的行。
  IntColumn get modifiedAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column<Object>> get primaryKey => {sourceId, itemId, unitId};
}

/// 下载的条目（v6，docs/architecture.md §4.5）：标题 / 封面快照与下载时 `detail()` 的 JSON 快照，
/// 源失效或离线时仍可打开目录。
@DataClassName('DownloadItemRow')
class DownloadItems extends Table {
  TextColumn get sourceId => text()();

  TextColumn get itemId => text()();

  TextColumn get title => text()();

  TextColumn get cover => text().nullable()();

  TextColumn get coverHeaders =>
      text().map(const StringMapConverter()).nullable()();

  /// `MediaType.name`。
  TextColumn get mediaType => text()();

  /// 最近一次加入下载时 `Detail` 的 JSON。
  TextColumn get detailJson => text()();

  DateTimeColumn get createdAt => dateTime()();

  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {sourceId, itemId};
}

/// 下载的 unit 及其状态（v6）。
@DataClassName('DownloadUnitRow')
class DownloadUnits extends Table {
  TextColumn get sourceId => text()();

  TextColumn get itemId => text()();

  TextColumn get unitId => text()();

  TextColumn get title => text()();

  /// 所在线路的名称（`unitGroupsOf` 的分组）与在线路中的下标。
  TextColumn get groupName => text()();

  IntColumn get unitIndex => integer()();

  /// `queued / running / paused / failed / done`，见 `shared/download` 的 `DownloadStatus`。
  TextColumn get status => text()();

  IntColumn get completedFiles => integer().withDefault(const Constant(0))();

  IntColumn get totalFiles => integer().withDefault(const Constant(0))();

  IntColumn get bytes => integer().withDefault(const Constant(0))();

  /// 最近一次失败 / 暂停的错误码（如 `E_CHALLENGE`）；用户手动暂停时为 null。
  TextColumn get errorCode => text().nullable()();

  /// 加入队列的顺序（同一时间加入的按线路下标）。
  IntColumn get queueOrder => integer()();

  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {sourceId, itemId, unitId};
}

/// WebDAV 同步的本机状态（v7，architecture §4.6），只有 `id = 1` 一行，首次需要时创建。
///
/// 密码不在这里：只存系统安全存储。
@DataClassName('SyncStateRow')
class SyncState extends Table {
  IntColumn get id => integer()();

  /// 本机的随机标识（合并平局时按字典序比较）。
  TextColumn get deviceId => text()();

  /// 同步正在把合并结果写回本地：触发器据此不改 `modified_at`、不记墓碑。只在同步的写入事务内为 true。
  BoolColumn get applying => boolean().withDefault(const Constant(false))();

  /// 是否启用自动同步（启动、回到前台、本地改动后）。
  BoolColumn get enabled => boolean().withDefault(const Constant(false))();

  /// 服务器地址；null 表示未配置（此时触发器不记墓碑）。
  TextColumn get serverUrl => text().nullable()();

  TextColumn get username => text().nullable()();

  /// 远端目录（相对服务器地址），如 `Tsumugi/`。
  TextColumn get remoteDir => text().nullable()();

  /// 上次成功同步的本地快照时刻减 1 ms（UTC 毫秒）；null 表示从未同步。
  IntColumn get lastSyncAt => integer().nullable()();

  /// 上次读到 / 写入的远端文件 ETag。
  TextColumn get remoteEtag => text().nullable()();

  /// 与 [remoteEtag] 对应的远端文件（压缩字节），GET 返回 304 时用于合并。
  BlobColumn get remoteSnapshot => blob().nullable()();

  /// 服务器不返回 ETag：退化为“读—合并—写”，设置页提示不支持并发保护。
  BoolColumn get conditionalUnsupported =>
      boolean().withDefault(const Constant(false))();

  /// 最近一次同步尝试的时间（UTC 毫秒）与错误（null 为成功）。
  IntColumn get lastAttemptAt => integer().nullable()();

  TextColumn get lastError => text().nullable()();

  /// 待用户确认安装的源（JSON 数组），每次同步按合并结果重算。
  TextColumn get pendingSourcesJson => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// 被删除的同步记录（v7）：集合名 + 主键（不足三段的用空串补齐）+ 删除时间。保留 90 天。
@DataClassName('SyncTombstoneRow')
class SyncTombstones extends Table {
  /// `library` / `itemProgress` / `unitProgress` / `sources` / `repositories`。
  TextColumn get collection => text()();

  TextColumn get key1 => text()();

  TextColumn get key2 => text().withDefault(const Constant(''))();

  TextColumn get key3 => text().withDefault(const Constant(''))();

  /// 删除时间（UTC 毫秒）。
  IntColumn get deletedAt => integer()();

  @override
  Set<Column<Object>> get primaryKey => {collection, key1, key2, key3};
}
