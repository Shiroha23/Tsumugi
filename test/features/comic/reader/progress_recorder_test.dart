import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/features/comic/reader/reader_providers.dart';
import 'package:tsumugi/shared/history/history_repository.dart';
import 'package:tsumugi/shared/library/library_item.dart';
import 'package:tsumugi/sources/model/common.dart';

class _FakeHistory implements HistoryRepository {
  final writes = <(String unitId, int? page)>[];

  @override
  Future<void> recordProgress(
    LibraryItem item, {
    required String unitId,
    required String unitTitle,
    int? page,
    int? pageCount,
    int? position,
    bool markRead = false,
  }) async => writes.add((unitId, page));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ComicReadingProgress _p(
  int page, {
  String? title = '第 1 话',
  String unit = 'c1',
}) => ComicReadingProgress(
  sourceId: 's',
  itemId: 'i',
  unitId: unit,
  unitTitle: title,
  pageIndex: page,
  pageCount: 10,
);

const _item = LibraryItem(
  sourceId: 's',
  itemId: 'i',
  title: 't',
  mediaType: MediaType.comic,
);

void main() {
  test('首次立即写入；间隔内只在到期时写入最新一次', () {
    fakeAsync((async) {
      final history = _FakeHistory();
      final recorder = ComicProgressRecorder(
        history: history,
        itemFor: (_) => _item,
      );
      recorder.report(_p(0));
      expect(history.writes, [('c1', 0)]);

      recorder.report(_p(1));
      recorder.report(_p(2));
      recorder.report(_p(3));
      expect(history.writes, hasLength(1));

      async.elapse(const Duration(seconds: 1));
      expect(history.writes, [('c1', 0), ('c1', 3)]);
    });
  });

  test('flush 立即写入待写进度', () {
    fakeAsync((async) {
      final history = _FakeHistory();
      final recorder = ComicProgressRecorder(
        history: history,
        itemFor: (_) => _item,
      );
      recorder.report(_p(0));
      recorder.report(_p(5));
      recorder.flush();
      expect(history.writes, [('c1', 0), ('c1', 5)]);
      async.elapse(const Duration(seconds: 2));
      expect(history.writes, hasLength(2));
    });
  });

  test('章节标题或条目信息未知时不写入', () {
    fakeAsync((async) {
      final history = _FakeHistory();
      var known = false;
      final recorder = ComicProgressRecorder(
        history: history,
        itemFor: (_) => known ? _item : null,
      );
      recorder.report(_p(0, title: null));
      recorder.report(_p(0));
      expect(history.writes, isEmpty);
      known = true;
      recorder.report(_p(0));
      expect(history.writes, [('c1', 0)]);
    });
  });

  test('换章时先写入上一章的待写进度（保证已读标记），新章节照常节流', () {
    fakeAsync((async) {
      final history = _FakeHistory();
      final recorder = ComicProgressRecorder(
        history: history,
        itemFor: (_) => _item,
      );
      recorder.report(_p(0));
      recorder.report(_p(9)); // 上一章最后一页，处于节流中
      recorder.report(_p(0, unit: 'c2', title: '第 2 话'));
      expect(history.writes, [('c1', 0), ('c1', 9)]);
      async.elapse(const Duration(seconds: 1));
      expect(history.writes, [('c1', 0), ('c1', 9), ('c2', 0)]);
    });
  });

  group('readingOrder', () {
    const detail = Detail(
      id: 'i',
      title: 't',
      groups: [
        UnitGroup(
          name: 'A',
          units: [Unit(id: 'a1', title: 'A1')],
        ),
        UnitGroup(
          name: 'B',
          units: [
            Unit(id: 'b1', title: 'B1'),
            Unit(id: 'b2', title: 'B2'),
          ],
        ),
      ],
    );

    test('默认取第一组；给出章节时取包含它的那一组', () {
      expect(readingOrder(detail).map((u) => u.id), ['a1']);
      expect(readingOrder(detail, 'b2').map((u) => u.id), ['b1', 'b2']);
      expect(readingOrder(detail, 'zz').map((u) => u.id), ['a1']);
    });

    test('units 优先于 groups', () {
      const withUnits = Detail(
        id: 'i',
        title: 't',
        units: [Unit(id: 'u1', title: 'U1')],
        groups: [
          UnitGroup(
            name: 'B',
            units: [Unit(id: 'b1', title: 'B1')],
          ),
        ],
      );
      expect(readingOrder(withUnits).map((u) => u.id), ['u1']);
      expect(readingOrder(withUnits, 'b1').map((u) => u.id), ['b1']);
    });
  });
}
