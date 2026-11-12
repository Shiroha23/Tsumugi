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
