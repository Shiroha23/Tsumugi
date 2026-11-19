import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/storage/app_database.dart';

import 'generated/schema.dart';
import 'generated/schema_v3.dart' as v3;
import 'generated/schema_v4.dart' as v4;

/// v3 → v4：已安装源保留，新增的 `settings_json` 为 null（全部取默认）。
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late SchemaVerifier verifier;

  setUpAll(() => verifier = SchemaVerifier(GeneratedHelper()));

  test('v3 → v4 keeps installed sources, settings start empty', () async {
    final schema = await verifier.schemaAt(3);
    final old = v3.DatabaseAtV3(schema.newConnection());
    await old
        .into(old.installedSources)
        .insert(
          const v3.InstalledSourcesData(
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
    await old.close();

    final db = AppDatabase(schema.newConnection());
    await verifier.migrateAndValidate(db, 4);
    await db.close();

    // 用 v4 的表定义读写（当前的 AppDatabase 已有更高版本才加的列）。
    final migrated = v4.DatabaseAtV4(schema.newConnection());
    final row = await migrated.select(migrated.installedSources).getSingle();
    expect(row.id, 'com.example.comic');
    expect(row.settingsJson, isNull);
    await (migrated.update(migrated.installedSources)).write(
      const v4.InstalledSourcesCompanion(settingsJson: Value('{"q":"low"}')),
    );
    expect(
      (await migrated.select(migrated.installedSources).getSingle())
          .settingsJson,
      '{"q":"low"}',
    );
    await migrated.close();
  });
}
