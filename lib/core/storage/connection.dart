import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:path_provider/path_provider.dart';

/// 数据库文件名（不含扩展名）。
const appDatabaseName = 'tsumugi';

/// 打开磁盘上的应用数据库，位于应用支持目录（而非用户的“文档”目录）。
/// 在后台 isolate 中执行 SQL。
QueryExecutor openAppDatabaseConnection() => driftDatabase(
  name: appDatabaseName,
  native: const DriftNativeOptions(
    databaseDirectory: getApplicationSupportDirectory,
  ),
);
