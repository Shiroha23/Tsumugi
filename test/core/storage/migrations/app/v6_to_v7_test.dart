import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/storage/app_database.dart';

import 'generated/schema.dart';
import 'generated/schema_v6.dart' as v6;

/// v6 → v7（WebDAV 同步）：原有行保留，`modified_at` 为 0；迁移后触发器生效。
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late SchemaVerifier verifier;

  setUpAll(() => verifier = SchemaVerifier(GeneratedHelper()));

  test('v6 → v7 keeps rows and installs change tracking', () async {
    final schema = await verifier.schemaAt(6);
    final old = v6.DatabaseAtV6(schema.newConnection());
    await old
        .into(old.libraryEntries)
        .insert(
          const v6.LibraryEntriesData(
            sourceId: 'com.example.comic',
            itemId: '/book/1',
            title: '虚构漫画',
            mediaType: 'comic',
            sortOrder: 0,
            addedAt: 0,
            updatedAt: 0,
          ),
        );
    await old.close();

    final db = AppDatabase(schema.newConnection());
    await verifier.migrateAndValidate(db, 7);

    final row = await db.select(db.libraryEntries).getSingle();
    expect(row.title, '虚构漫画');
    expect(row.modifiedAt, 0);

    await (db.update(db.libraryEntries))
        .write(const LibraryEntriesCompanion(category: Value('在读')));
    expect(
      (await db.select(db.libraryEntries).getSingle()).modifiedAt,
      greaterThan(0),
    );
    expect(await db.select(db.syncState).get(), isEmpty);
    // 仓库订阅也有改动跟踪。
    await db
        .into(db.sourceRepositories)
        .insert(
          SourceRepositoriesCompanion.insert(
            url: 'https://example.com/index.json',
            name: 'Repo',
            addedAt: DateTime.utc(2026, 11, 19),
            indexJson: '{}',
            indexSha256: 'def',
          ),
        );
    expect(
      (await db.select(db.sourceRepositories).getSingle()).modifiedAt,
      greaterThan(0),
    );
    expect(await db.select(db.syncTombstones).get(), isEmpty);
    await db.close();
  });
}
