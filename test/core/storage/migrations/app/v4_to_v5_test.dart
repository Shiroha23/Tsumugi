import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/storage/app_database.dart';

import 'generated/schema.dart';
import 'generated/schema_v4.dart' as v4;

/// v4 → v5：新增 `source_repositories`；已安装源保留，`repository_url` 为 null。
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late SchemaVerifier verifier;

  setUpAll(() => verifier = SchemaVerifier(GeneratedHelper()));

  test('v4 → v5 keeps installed sources, adds repositories table', () async {
    final schema = await verifier.schemaAt(4);
    final old = v4.DatabaseAtV4(schema.newConnection());
    await old
        .into(old.installedSources)
        .insert(
          const v4.InstalledSourcesData(
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
            settingsJson: '{"q":"low"}',
          ),
        );
    await old.close();

    final db = AppDatabase(schema.newConnection());
    await verifier.migrateAndValidate(db, 5);

    final row = await db.select(db.installedSources).getSingle();
    expect(row.id, 'com.example.comic');
    expect(row.settingsJson, '{"q":"low"}');
    expect(row.repositoryUrl, isNull);
    expect(await db.select(db.sourceRepositories).get(), isEmpty);
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
    expect(await db.select(db.sourceRepositories).get(), hasLength(1));
    await db.close();
  });
}
