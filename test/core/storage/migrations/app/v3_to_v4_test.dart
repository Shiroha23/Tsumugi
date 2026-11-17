import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/storage/app_database.dart';

import 'generated/schema.dart';
import 'generated/schema_v3.dart' as v3;

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

    final row = await db.select(db.installedSources).getSingle();
    expect(row.id, 'com.example.comic');
    expect(row.settingsJson, isNull);
    await (db.update(db.installedSources)).write(
      const InstalledSourcesCompanion(settingsJson: Value('{"q":"low"}')),
    );
    expect(
      (await db.select(db.installedSources).getSingle()).settingsJson,
      '{"q":"low"}',
    );
    await db.close();
  });
}
