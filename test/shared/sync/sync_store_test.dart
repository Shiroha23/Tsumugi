import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/storage/app_database.dart';
import 'package:tsumugi/shared/history/history_repository.dart';
import 'package:tsumugi/shared/library/library_item.dart';
import 'package:tsumugi/shared/library/library_repository.dart';
import 'package:tsumugi/shared/sync/sync_store.dart';
import 'package:tsumugi/sources/model/common.dart';
import 'package:tsumugi/sources/registry/source_registry.dart';

import '../../core/storage/test_database.dart';

const _item = LibraryItem(
  sourceId: 'com.example.comic',
  itemId: '/book/1',
  title: '虚构漫画',
  mediaType: MediaType.comic,
  cover: 'https://img.example.com/1.png',
);

/// `modified_at` 由触发器维护（architecture §4.6）：各写入路径都无需手写。
void main() {
  late AppDatabase db;
  late SyncStore store;
  late LibraryRepository library;
  late HistoryRepository history;
  late SourceRegistry registry;

  setUp(() {
    db = openTestDatabase();
    store = SyncStore(db);
    library = LibraryRepository(db);
    history = HistoryRepository(db);
    registry = SourceRegistry(db);
  });

  tearDown(() => db.close());

  Future<int> libraryModified() async =>
      (await db.select(db.libraryEntries).getSingle()).modifiedAt;

  /// 等到 SQLite 时钟前进（触发器的时间精度为毫秒）。
  Future<void> tick() => Future<void>.delayed(const Duration(milliseconds: 3));

  Future<List<SyncTombstoneRow>> tombstones() =>
      db.select(db.syncTombstones).get();

  Future<void> configureServer() => store.saveConfig(
    serverUrl: 'https://dav.example.com/',
    username: 'alice',
    remoteDir: 'Tsumugi/',
  );

  test(
    'library writes set modified_at; metadata-only refresh does not',
    () async {
      final before = await store.sqlNow();
      await library.add(_item);
      final added = await libraryModified();
      expect(added, greaterThanOrEqualTo(before));

      await tick();
      // 详情页刷新元数据：标题封面没变，只有 updatedAt 变化，不算同步改动。
      await library.updateMetadata(_item);
      expect(await libraryModified(), added);

      await tick();
      await library.setCategory(_item.sourceId, _item.itemId, '收藏');
      final categorized = await libraryModified();
      expect(categorized, greaterThan(added));

      await tick();
      await library.updateMetadata(
        const LibraryItem(
          sourceId: 'com.example.comic',
          itemId: '/book/1',
          title: '新标题',
          mediaType: MediaType.comic,
        ),
      );
      expect(await libraryModified(), greaterThan(categorized));
    },
  );

  test('progress writes set modified_at on both progress tables', () async {
    await history.recordProgress(
      _item,
      unitId: 'c1',
      unitTitle: '第 1 话',
      page: 0,
      pageCount: 10,
    );
    final item = await db.select(db.itemProgressEntries).getSingle();
    final unit = await db.select(db.unitProgressEntries).getSingle();
    expect(item.modifiedAt, greaterThan(0));
    expect(unit.modifiedAt, greaterThan(0));

    await tick();
    await history.setUnitRead(_item.sourceId, _item.itemId, 'c1', read: true);
    expect(
      (await db.select(db.unitProgressEntries).getSingle()).modifiedAt,
      greaterThan(unit.modifiedAt),
    );
  });

  test('source registry writes set modified_at', () async {
    final manifest = File('test/fixtures/sources/settings_comic.json')
        .readAsStringSync();
    await registry.importText(manifest);
    Future<int> modified() async =>
        (await db.select(db.installedSources).getSingle()).modifiedAt;
    final installed = await modified();
    expect(installed, greaterThan(0));

    await tick();
    await registry.setEnabled('com.example.settings', false);
    final disabled = await modified();
    expect(disabled, greaterThan(installed));

    await tick();
    await registry.setSettings('com.example.settings', {'quality': 'low'});
    final configured = await modified();
    expect(configured, greaterThan(disabled));

    await tick();
    await registry.reorder(['com.example.settings']);
    // 排序值没变：不算改动。
    expect(await modified(), configured);
  });

  test('tombstones are recorded only while a server is configured', () async {
    await library.add(_item);
    await library.remove(_item.sourceId, _item.itemId);
    expect(await tombstones(), isEmpty);

    await configureServer();
    await library.add(_item);
    await history.recordProgress(_item, unitId: 'c1', unitTitle: '第 1 话');
    await library.remove(_item.sourceId, _item.itemId);
    await history.removeHistory(_item.sourceId, _item.itemId);
    final rows = await tombstones();
    expect(
      rows.map((t) => (t.collection, t.key1, t.key2, t.key3)),
      unorderedEquals([
        ('library', 'com.example.comic', '/book/1', ''),
        ('itemProgress', 'com.example.comic', '/book/1', ''),
        ('unitProgress', 'com.example.comic', '/book/1', 'c1'),
      ]),
    );
    expect(rows.every((t) => t.deletedAt > 0), isTrue);

    // 重新加入书架：墓碑被删除。
    await library.add(_item);
    expect(
      (await tombstones()).map((t) => t.collection),
      unorderedEquals(['itemProgress', 'unitProgress']),
    );
  });

  test('applying flag suppresses the triggers', () async {
    await configureServer();
    await (db.update(db.syncState)..where((t) => t.id.equals(1))).write(
      const SyncStateCompanion(applying: Value(true)),
    );
    await db
        .into(db.libraryEntries)
        .insert(
          LibraryEntriesCompanion.insert(
            sourceId: 's',
            itemId: 'i',
            title: 't',
            mediaType: 'comic',
            addedAt: DateTime(2026),
            updatedAt: DateTime(2026),
            modifiedAt: const Value(42),
          ),
        );
    expect(await libraryModified(), 42);
    await library.setCategory('s', 'i', 'x');
    expect(await libraryModified(), 42);
    await library.remove('s', 'i');
    expect(await tombstones(), isEmpty);
  });

  test('changing the server resets sync state and tombstones', () async {
    await configureServer();
    await store.recordSuccess(
      lastSyncAt: 100,
      etag: '"v1"',
      snapshot: Uint8List.fromList([1, 2]),
      conditionalUnsupported: true,
      attemptAt: 100,
    );
    await library.add(_item);
    await library.remove(_item.sourceId, _item.itemId);
    expect(await tombstones(), hasLength(1));

    // 同一配置再保存一次：不重置。
    await configureServer();
    expect((await store.ensureState()).lastSyncAt, 100);

    await store.saveConfig(
      serverUrl: 'https://other.example.com/',
      username: 'alice',
      remoteDir: 'Tsumugi/',
    );
    final state = await store.ensureState();
    expect(state.lastSyncAt, isNull);
    expect(state.remoteEtag, isNull);
    expect(state.remoteSnapshot, isNull);
    expect(state.conditionalUnsupported, isFalse);
    expect(await tombstones(), isEmpty);
  });

  test('hasLocalChanges compares against the last sync time', () async {
    await configureServer();
    expect(await store.hasLocalChanges(), isTrue, reason: '从未同步');
    final now = await store.sqlNow();
    await store.recordSuccess(
      lastSyncAt: now,
      etag: null,
      snapshot: null,
      conditionalUnsupported: false,
      attemptAt: now,
    );
    expect(await store.hasLocalChanges(), isFalse);
    await tick();
    await library.add(_item);
    expect(await store.hasLocalChanges(), isTrue);
  });

  test('device id is random and stable', () async {
    final a = await store.ensureState();
    expect(a.deviceId, matches(RegExp(r'^[0-9a-f]{32}$')));
    expect((await store.ensureState()).deviceId, a.deviceId);
    final other = openTestDatabase();
    addTearDown(other.close);
    expect((await SyncStore(other).ensureState()).deviceId, isNot(a.deviceId));
  });
}
