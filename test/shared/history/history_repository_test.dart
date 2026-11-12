import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/storage/app_database.dart';
import 'package:tsumugi/shared/history/providers.dart';
import 'package:tsumugi/shared/library/providers.dart';
import 'package:tsumugi/sources/model/common.dart';

import '../../core/storage/test_database.dart';

const _src = 'com.example.comic';

LibraryItem item(String id, {String? title}) => LibraryItem(
  sourceId: _src,
  itemId: id,
  title: title ?? 'Title $id',
  mediaType: MediaType.comic,
);

void main() {
  late AppDatabase db;
  late HistoryRepository repo;
  late DateTime now;

  setUp(() {
    db = openTestDatabase();
    now = DateTime.utc(2026, 11, 1);
    repo = HistoryRepository(db, clock: () => now);
  });
  tearDown(() => db.close());

  void tick() => now = now.add(const Duration(minutes: 1));

  test('recordProgress keeps only the latest progress per item', () async {
    expect(await repo.latestProgress(_src, 'a'), isNull);
    await repo.recordProgress(
      item('a'),
      unitId: 'c1',
      unitTitle: '第 1 话',
      page: 3,
      pageCount: 20,
    );
    tick();
    await repo.recordProgress(
      item('a', title: 'Renamed'),
      unitId: 'c2',
      unitTitle: '第 2 话',
      page: 0,
    );

    final p = (await repo.latestProgress(_src, 'a'))!;
    expect(p.unitId, 'c2');
    expect(p.unitTitle, '第 2 话');
    expect(p.page, 0);
    expect(p.pageCount, isNull);
    expect(p.item.title, 'Renamed');
    expect(p.updatedAt.toUtc(), now);
    expect(await repo.watchHistory().first, hasLength(1));

    // 之前的 unit 仍保留自己的页码。
    final c1 = (await repo.unitProgress(_src, 'a', 'c1'))!;
    expect(c1.page, 3);
    expect(c1.pageCount, 20);
    expect(c1.read, isFalse);
  });

  test(
    'reaching the last page marks the unit read, and it stays read',
    () async {
      Future<void> at(int page) => repo.recordProgress(
        item('a'),
        unitId: 'c1',
        unitTitle: '1',
        page: page,
        pageCount: 20,
      );
      await at(18);
      expect(await repo.isUnitRead(_src, 'a', 'c1'), isFalse);
      await at(19);
      expect(await repo.isUnitRead(_src, 'a', 'c1'), isTrue);
      // 回翻不会取消已读。
      await at(2);
      expect(await repo.isUnitRead(_src, 'a', 'c1'), isTrue);
      expect((await repo.unitProgress(_src, 'a', 'c1'))!.page, 2);
    },
  );

  test('markRead and setUnitRead', () async {
    await repo.recordProgress(
      item('a'),
      unitId: 'c1',
      unitTitle: '1',
      position: 1200,
      markRead: true,
    );
    expect(await repo.isUnitRead(_src, 'a', 'c1'), isTrue);
    expect((await repo.latestProgress(_src, 'a'))!.position, 1200);

    await repo.setUnitRead(_src, 'a', 'c1', read: false);
    expect(await repo.isUnitRead(_src, 'a', 'c1'), isFalse);
    expect(
      (await repo.unitProgress(_src, 'a', 'c1'))!.position,
      1200,
      reason: '取消已读不清除 unit 内进度',
    );

    // 手动标记不产生历史。
    await repo.setUnitRead(_src, 'b', 'c9', read: true);
    expect(await repo.isUnitRead(_src, 'b', 'c9'), isTrue);
    expect(await repo.latestProgress(_src, 'b'), isNull);
    expect(await repo.isUnitRead(_src, 'b', 'unknown'), isFalse);
  });

  test('watchReadUnitIds', () async {
    await repo.setUnitRead(_src, 'a', 'c1', read: true);
    await repo.setUnitRead(_src, 'a', 'c2', read: true);
    await repo.setUnitRead(_src, 'a', 'c3', read: false);
    await repo.setUnitRead(_src, 'b', 'c1', read: true);
    expect(await repo.watchReadUnitIds(_src, 'a').first, {'c1', 'c2'});
  });

  test('watchHistory orders by most recent and honours limit', () async {
    for (final id in ['a', 'b', 'c']) {
      await repo.recordProgress(item(id), unitId: 'u', unitTitle: 'u', page: 0);
      tick();
    }
    // 重新阅读 a，使其排到最前。
    await repo.recordProgress(item('a'), unitId: 'u', unitTitle: 'u', page: 1);

    final all = await repo.watchHistory().first;
    expect([for (final p in all) p.itemId], ['a', 'c', 'b']);
    final two = await repo.watchHistory(limit: 2).first;
    expect([for (final p in two) p.itemId], ['a', 'c']);
  });

  test('removeHistory clears unit progress unless asked to keep it', () async {
    for (final id in ['a', 'b']) {
      await repo.recordProgress(
        item(id),
        unitId: 'c1',
        unitTitle: '1',
        markRead: true,
      );
    }

    await repo.removeHistory(_src, 'a');
    expect(await repo.latestProgress(_src, 'a'), isNull);
    expect(await repo.isUnitRead(_src, 'a', 'c1'), isFalse);

    await repo.removeHistory(_src, 'b', keepUnitProgress: true);
    expect(await repo.latestProgress(_src, 'b'), isNull);
    expect(await repo.isUnitRead(_src, 'b', 'c1'), isTrue);
  });

  test('clearHistory removes everything', () async {
    await repo.recordProgress(item('a'), unitId: 'c1', unitTitle: '1');
    await repo.setUnitRead(_src, 'x', 'c1', read: true);
    await repo.clearHistory();
    expect(await repo.watchHistory().first, isEmpty);
    expect(await repo.isUnitRead(_src, 'x', 'c1'), isFalse);
  });

  test('history is independent of the library', () async {
    final library = LibraryRepository(db);
    await library.add(item('a'));
    await repo.recordProgress(item('a'), unitId: 'c1', unitTitle: '1');
    await library.remove(_src, 'a');
    expect(await repo.latestProgress(_src, 'a'), isNotNull);
    await library.add(item('a'));
    await repo.removeHistory(_src, 'a');
    expect(await library.contains(_src, 'a'), isTrue);
  });
}
