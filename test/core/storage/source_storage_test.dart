import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/storage/source_storage.dart';

import 'test_database.dart';

void main() {
  for (final (name, make) in [
    (
      'drift',
      () {
        final db = openTestDatabase();
        addTearDown(db.close);
        return DriftSourceStorage(db) as SourceStorage;
      },
    ),
    ('memory', () => MemorySourceStorage() as SourceStorage),
  ]) {
    group(name, () {
      test('quota is atomic under concurrent writes', () async {
        final store = make();
        // 每条 2 + 17 = 19 码点，配额 40 只容得下两条。
        final results = await Future.wait([
          for (var i = 0; i < 5; i++)
            store.write('s', 'k$i', '"${'x' * 15}"', quota: 40),
        ]);
        expect(results.where((r) => r), hasLength(2));
        expect(await store.usage('s'), 38);
      });

      test('usage counts code points (emoji is one unit)', () async {
        final store = make();
        final emoji = '"${'😀' * 8}"'; // 10 码点，20 个 UTF-16 单元
        expect(await store.write('s', 'a', emoji, quota: 30), isTrue);
        expect(await store.write('s', 'b', emoji, quota: 30), isTrue);
        expect(await store.usage('s'), 22);
        expect(await store.write('s', 'c', emoji, quota: 30), isFalse);
        // 覆盖同一键按新旧差值计算。
        expect(await store.write('s', 'a', emoji, quota: 22), isTrue);
      });

      test('cancelled operations are skipped', () async {
        final store = make();
        expect(
          await store.write('s', 'k', '1', isCancelled: () => true),
          isFalse,
        );
        expect(await store.read('s', 'k'), isNull);
        await store.write('s', 'k', '1');
        expect(await store.delete('s', 'k', isCancelled: () => true), isFalse);
        expect(await store.read('s', 'k'), '1');
      });

      test('sources are isolated', () async {
        final store = make();
        await store.write('a', 'k', '1');
        expect(await store.read('b', 'k'), isNull);
        await store.clear('a');
        expect(await store.read('a', 'k'), isNull);
      });
    });
  }
}
