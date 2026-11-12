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

  @override
  Set<Column<Object>> get primaryKey => {id};
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

  @override
  Set<Column<Object>> get primaryKey => {sourceId, itemId, unitId};
}
