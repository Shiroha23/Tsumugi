import 'package:drift/drift.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'app_database.steps.dart';
import 'connection.dart';
import 'tables.dart';

export 'tables.dart';

part 'app_database.g.dart';

/// 应用主数据库。
///
/// 迁移策略（docs/architecture.md §4.1）：
/// - 每次改表结构都要把 [schemaVersion] 加一，并运行
///   `dart run drift_dev make-migrations`，它会把新 schema 导出到 `drift_schemas/`，
///   生成 `app_database.steps.dart` 与 `test/core/storage/migrations/` 下的迁移测试；
///   然后在 [migration] 的 `onUpgrade` 中用 `stepByStep` 写出 from→to 的每一步。
/// - 已发布的 `drift_schemas/*.json` 不可修改。
/// - 不支持降级：数据库版本高于 [schemaVersion]（用户装回旧版客户端）时拒绝打开，避免损坏数据。
@DriftDatabase(
  tables: [
    InstalledSources,
    SourceStorageEntries,
    LibraryEntries,
    ItemProgressEntries,
    UnitProgressEntries,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  @override
  int get schemaVersion => 3;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    onUpgrade: (m, from, to) async {
      if (from > to) {
        throw StateError('数据库版本 $from 高于客户端支持的 $to，请更新客户端');
      }
      await stepByStep(
        // v2：脚本源的按源 KV 存储（tsumugi.storage）。
        from1To2: (m, schema) async {
          await m.createTable(schema.sourceStorageEntries);
        },
        // v3：书架、条目进度（兼作历史）、按 unit 的进度与已读标记。
        from2To3: (m, schema) async {
          await m.createTable(schema.libraryEntries);
          await m.createTable(schema.itemProgressEntries);
          await m.createTable(schema.unitProgressEntries);
          await m.createIndex(schema.itemProgressUpdatedAt);
        },
      )(m, from, to);
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );
}

@Riverpod(keepAlive: true)
AppDatabase appDatabase(Ref ref) {
  final db = AppDatabase(openAppDatabaseConnection());
  ref.onDispose(db.close);
  return db;
}
