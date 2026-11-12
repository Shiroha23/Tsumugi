import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/storage/app_database.dart';
import 'package:tsumugi/shared/library/providers.dart';
import 'package:tsumugi/sources/model/common.dart';

import '../../core/storage/test_database.dart';

LibraryItem item(
  String id, {
  MediaType type = MediaType.comic,
  String? title,
  String? cover,
  Headers? headers,
}) => LibraryItem(
  sourceId: 'com.example.comic',
  itemId: id,
  title: title ?? 'Title $id',
  mediaType: type,
  cover: cover,
  coverHeaders: headers,
);

void main() {
  late AppDatabase db;
  late LibraryRepository repo;
  late DateTime now;

  setUp(() {
    db = openTestDatabase();
    now = DateTime.utc(2026, 11, 1);
    repo = LibraryRepository(db, clock: () => now);
  });
  tearDown(() => db.close());

  test('add / contains / remove', () async {
    expect(await repo.contains('com.example.comic', 'a'), isFalse);
    await repo.add(
      item(
        'a',
        cover: 'https://comic.example.com/a.jpg',
        headers: {'Referer': 'https://comic.example.com/'},
      ),
    );
    expect(await repo.contains('com.example.comic', 'a'), isTrue);
    expect(await repo.contains('com.example.other', 'a'), isFalse);

    final e = (await repo.get('com.example.comic', 'a'))!;
    expect(e.item.cover, 'https://comic.example.com/a.jpg');
    expect(e.item.coverHeaders, {'Referer': 'https://comic.example.com/'});
    expect(e.item.mediaType, MediaType.comic);
    expect(e.addedAt.toUtc(), now);

    expect(await repo.remove('com.example.comic', 'a'), isTrue);
    expect(await repo.remove('com.example.comic', 'a'), isFalse);
    expect(await repo.contains('com.example.comic', 'a'), isFalse);
  });

  test('re-adding keeps addedAt and category, refreshes metadata', () async {
    await repo.add(item('a'), category: '追更');
    final added = now;
    now = now.add(const Duration(days: 1));
    await repo.add(item('a', title: 'New title'));

    final rows = await repo.watchEntries().first;
    expect(rows, hasLength(1));
    final e = rows.single;
    expect(e.item.title, 'New title');
    expect(e.category, '追更');
    expect(e.addedAt.toUtc(), added);
    expect(e.updatedAt.toUtc(), now);
  });

  test('updateMetadata only touches existing entries', () async {
    await repo.updateMetadata(item('missing'));
    expect(await repo.contains('com.example.comic', 'missing'), isFalse);

    await repo.add(item('a'));
    await repo.updateMetadata(item('a', title: 'Renamed', cover: 'c.jpg'));
    final e = (await repo.get('com.example.comic', 'a'))!;
    expect(e.item.title, 'Renamed');
    expect(e.item.cover, 'c.jpg');
  });

  test('watchEntries filters by type and orders by updatedAt desc', () async {
    await repo.add(item('old'));
    now = now.add(const Duration(minutes: 1));
    await repo.add(item('novel', type: MediaType.novel));
    now = now.add(const Duration(minutes: 1));
    await repo.add(item('new'));

    final all = await repo.watchEntries().first;
    expect([for (final e in all) e.itemId], ['new', 'novel', 'old']);
    final comics = await repo.watchEntries(type: MediaType.comic).first;
    expect([for (final e in comics) e.itemId], ['new', 'old']);
  });

  test('watchEntries filters by category', () async {
    await repo.add(item('a'), category: 'x');
    await repo.add(item('b'));
    await repo.setCategory('com.example.comic', 'b', 'y');
    final x = await repo.watchEntries(category: 'x').first;
    expect([for (final e in x) e.itemId], ['a']);
  });

  test('watchContains emits on add / remove', () async {
    final values = <bool>[];
    final sub = repo.watchContains('com.example.comic', 'a').listen(values.add);
    await pumpEventQueue();
    await repo.add(item('a'));
    await pumpEventQueue();
    await repo.remove('com.example.comic', 'a');
    await pumpEventQueue();
    await sub.cancel();
    expect(values, [false, true, false]);
  });

  test('rows with an unknown media type are skipped', () async {
    await repo.add(item('a'));
    await db.customStatement(
      "UPDATE library_entries SET media_type = 'hologram'",
    );
    expect(await repo.watchEntries().first, isEmpty);
    expect(await repo.get('com.example.comic', 'a'), isNull);
  });

  test('LibraryItem.fromSearchItem copies fields', () {
    final i = LibraryItem.fromSearchItem(
      'com.example.comic',
      MediaType.comic,
      const SearchItem(
        id: 'x',
        title: 'X',
        cover: 'c',
        coverHeaders: {'a': 'b'},
      ),
    );
    expect(
      i,
      const LibraryItem(
        sourceId: 'com.example.comic',
        itemId: 'x',
        title: 'X',
        mediaType: MediaType.comic,
        cover: 'c',
        coverHeaders: {'a': 'b'},
      ),
    );
  });
}
