import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/storage/app_database.dart';

import 'generated/schema.dart';
import 'generated/schema_v7.dart' as v7;

/// v7 → v8（视频下载的清晰度）：原有的下载 unit 保留，`stream_label` 为 null。
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late SchemaVerifier verifier;

  setUpAll(() => verifier = SchemaVerifier(GeneratedHelper()));

  test('v7 → v8 keeps download units', () async {
    final schema = await verifier.schemaAt(7);
    final old = v7.DatabaseAtV7(schema.newConnection());
    await old
        .into(old.downloadUnits)
        .insert(
          const v7.DownloadUnitsData(
            sourceId: 'com.example.comic',
            itemId: '/book/1',
            unitId: '/book/1/ch/1',
            title: '第 1 话',
            groupName: '默认',
            unitIndex: 0,
            status: 'done',
            completedFiles: 3,
            totalFiles: 3,
            bytes: 100,
            queueOrder: 0,
            updatedAt: 0,
          ),
        );
    await old.close();

    final db = AppDatabase(schema.newConnection());
    await verifier.migrateAndValidate(db, 8);
    final row = await db.select(db.downloadUnits).getSingle();
    expect(row.title, '第 1 话');
    expect(row.status, 'done');
    expect(row.streamLabel, isNull);
    await db.close();
  });
}
