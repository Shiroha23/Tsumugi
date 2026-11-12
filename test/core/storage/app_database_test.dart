import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/storage/app_database.dart';

import 'test_database.dart';

InstalledSourcesCompanion _row(String id, {int sortOrder = 0}) =>
    InstalledSourcesCompanion.insert(
      id: id,
      name: 'Name $id',
      type: 'comic',
      version: '1.0.0',
      apiVersion: 1,
      sortOrder: sortOrder,
      installedAt: DateTime.utc(2026, 11, 1),
      updatedAt: DateTime.utc(2026, 11, 1),
      originKind: SourceOriginKind.local,
      manifestSha256: 'abc',
      manifestJson: '{}',
    );

void main() {
  late AppDatabase db;

  setUp(() => db = openTestDatabase());
  tearDown(() => db.close());

  test('schemaVersion 为 1，建表后可读写', () async {
    expect(db.schemaVersion, 1);
    await db.into(db.installedSources).insert(_row('com.example.a'));

    final rows = await db.select(db.installedSources).get();
    expect(rows, hasLength(1));
    final r = rows.single;
    expect(r.id, 'com.example.a');
    expect(r.enabled, isTrue, reason: 'enabled 默认 true');
    expect(r.originKind, SourceOriginKind.local);
    expect(r.originUrl, isNull);
    expect(r.installedAt.toUtc(), DateTime.utc(2026, 11, 1));
  });

  test('id 是主键', () async {
    await db.into(db.installedSources).insert(_row('com.example.a'));
    expect(
      () => db.into(db.installedSources).insert(_row('com.example.a')),
      throwsA(isA<Exception>()),
    );
  });

  test('数据库版本高于客户端时拒绝打开', () async {
    final newer = openTestDatabase(
      setup: (raw) => raw.execute('PRAGMA user_version = 2'),
    );
    addTearDown(newer.close);
    await expectLater(
      newer.select(newer.installedSources).get(),
      throwsA(isA<StateError>()),
    );
  });

  test('首次打开写入 user_version', () async {
    await db.select(db.installedSources).get();
    final v = await db.customSelect('PRAGMA user_version').getSingle();
    expect(v.data.values.single, 1);
  });

  test('watch 在写入后推送', () async {
    final stream = db.select(db.installedSources).watch();
    final ids = stream.map((rows) => rows.map((r) => r.id).toList());
    final expectation = expectLater(
      ids,
      emitsInOrder([
        <String>[],
        ['com.example.a'],
      ]),
    );
    await Future<void>.delayed(Duration.zero);
    await db.into(db.installedSources).insert(_row('com.example.a'));
    await expectation;
  });
}
