import 'package:drift/drift.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/storage/app_database.dart';

import 'generated/schema.dart';
import 'generated/schema_v2.dart' as v2;
import 'generated/schema_v3.dart' as v3;

/// v2 → v3：已有数据保留，新表（书架、进度）可用。
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late SchemaVerifier verifier;

  setUpAll(() => verifier = SchemaVerifier(GeneratedHelper()));

  test('v2 → v3 keeps installed sources and storage', () async {
    final schema = await verifier.schemaAt(2);
    final old = v2.DatabaseAtV2(schema.newConnection());
    await old
        .into(old.installedSources)
        .insert(
          const v2.InstalledSourcesData(
            id: 'com.example.comic',
            name: 'Example',
            type: 'comic',
            version: '1.0.0',
            apiVersion: 1,
            enabled: 1,
            sortOrder: 0,
            installedAt: 0,
            updatedAt: 0,
            originKind: 'local',
            manifestSha256: 'abc',
            manifestJson: '{}',
          ),
        );
    await old
        .into(old.sourceStorageEntries)
        .insert(
          const v2.SourceStorageEntriesData(
            sourceId: 'com.example.comic',
            key: 'k',
            value: '1',
          ),
        );
    await old.close();

    final db = AppDatabase(schema.newConnection());
    await verifier.migrateAndValidate(db, 3);
    await db.close();

    // 用 v3 的表定义读写（当前的 AppDatabase 已有更高版本才加的列）。
    final migrated = v3.DatabaseAtV3(schema.newConnection());
    expect(
      await migrated.select(migrated.installedSources).get(),
      hasLength(1),
    );
    expect(
      await migrated.select(migrated.sourceStorageEntries).get(),
      hasLength(1),
    );
    await migrated
        .into(migrated.libraryEntries)
        .insert(
          v3.LibraryEntriesCompanion.insert(
            sourceId: 'com.example.comic',
            itemId: 'a',
            title: 'A',
            mediaType: 'comic',
            addedAt: 0,
            updatedAt: 0,
            coverHeaders: Value(
              const StringMapConverter().toSql({
                'Referer': 'https://comic.example.com/',
              }),
            ),
          ),
        );
    final row = await migrated.select(migrated.libraryEntries).getSingle();
    expect(const StringMapConverter().fromSql(row.coverHeaders!), {
      'Referer': 'https://comic.example.com/',
    });
    expect(row.sortOrder, 0);
    await migrated.close();
  });
}
