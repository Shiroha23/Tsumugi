import 'package:drift/drift.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/storage/app_database.dart';

import 'generated/schema.dart';
import 'generated/schema_v2.dart' as v2;

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

    expect(await db.select(db.installedSources).get(), hasLength(1));
    expect(await db.select(db.sourceStorageEntries).get(), hasLength(1));
    await db
        .into(db.libraryEntries)
        .insert(
          LibraryEntriesCompanion.insert(
            sourceId: 'com.example.comic',
            itemId: 'a',
            title: 'A',
            mediaType: 'comic',
            addedAt: DateTime.utc(2026),
            updatedAt: DateTime.utc(2026),
            coverHeaders: const Value({
              'Referer': 'https://comic.example.com/',
            }),
          ),
        );
    final row = await db.select(db.libraryEntries).getSingle();
    expect(row.coverHeaders, {'Referer': 'https://comic.example.com/'});
    expect(row.sortOrder, 0);
    await db.close();
  });
}
