import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:tsumugi/core/storage/app_database.dart';

/// 内存 SQLite 上的 [AppDatabase]，供测试使用。
AppDatabase openTestDatabase({void Function(dynamic rawDb)? setup}) {
  // 每个测试各自一个内存库，不存在共享 executor 的问题。
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  return AppDatabase(
    DatabaseConnection(
      NativeDatabase.memory(setup: setup),
      // widget 测试中避免关闭时残留计时器。
      closeStreamsSynchronously: true,
    ),
  );
}
