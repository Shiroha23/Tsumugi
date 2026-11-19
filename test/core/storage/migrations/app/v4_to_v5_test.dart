import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/storage/app_database.dart';

import 'generated/schema.dart';
import 'generated/schema_v4.dart' as v4;
import 'generated/schema_v5.dart' as v5;

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
    await db.close();

    // 用 v5 的表定义读写（当前的 AppDatabase 已有更高版本才加的列）。
    final migrated = v5.DatabaseAtV5(schema.newConnection());
    final row = await migrated.select(migrated.installedSources).getSingle();
    expect(row.id, 'com.example.comic');
    expect(row.settingsJson, '{"q":"low"}');
    expect(row.repositoryUrl, isNull);
    expect(await migrated.select(migrated.sourceRepositories).get(), isEmpty);
    await migrated
        .into(migrated.sourceRepositories)
        .insert(
          v5.SourceRepositoriesCompanion.insert(
            url: 'https://example.com/index.json',
            name: 'Repo',
            addedAt: 0,
            indexJson: '{}',
            indexSha256: 'def',
          ),
        );
    expect(
      await migrated.select(migrated.sourceRepositories).get(),
      hasLength(1),
    );
    await migrated.close();
  });
}
