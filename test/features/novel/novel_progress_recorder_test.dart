import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/features/novel/reader/novel_reader_providers.dart';
import 'package:tsumugi/shared/history/history_repository.dart';
import 'package:tsumugi/shared/library/library_item.dart';
import 'package:tsumugi/sources/model/common.dart';

class _FakeHistory implements HistoryRepository {
  final writes = <(String unitId, int? position, bool read)>[];

  @override
  Future<void> recordProgress(
    LibraryItem item, {
    required String unitId,
    required String unitTitle,
    int? page,
    int? pageCount,
    int? position,
    bool markRead = false,
  }) async => writes.add((unitId, position, markRead));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

NovelReadingProgress _p(
  int position, {
  String unit = 'c1',
  String? title = '第一章',
  bool end = false,
}) => NovelReadingProgress(
  sourceId: 's',
  itemId: 'i',
  unitId: unit,
  unitTitle: title,
  position: position,
  length: 1000,
  atEnd: end,
);

const _item = LibraryItem(
  sourceId: 's',
  itemId: 'i',
  title: 't',
  mediaType: MediaType.novel,
);

void main() {
  test('首次立即写入；间隔内只在到期时写入最新位置；标题未知不写', () {
    fakeAsync((async) {
      final history = _FakeHistory();
      final recorder = NovelProgressRecorder(
        history: history,
        itemFor: (_) => _item,
      );
      recorder.report(_p(0, title: null));
      expect(history.writes, isEmpty);
      recorder.report(_p(0));
      recorder.report(_p(10));
      recorder.report(_p(20));
      expect(history.writes, [('c1', 0, false)]);
      async.elapse(const Duration(seconds: 1));
      expect(history.writes, [('c1', 0, false), ('c1', 20, false)]);
    });
  });

  test('换章先写上一章；读到末尾的标记不会被随后的位置冲掉', () {
    fakeAsync((async) {
      final history = _FakeHistory();
      final recorder = NovelProgressRecorder(
        history: history,
        itemFor: (_) => _item,
      );
      recorder.report(_p(0));
      recorder.report(_p(990, end: true));
      recorder.report(_p(900));
      expect(history.writes, [('c1', 0, false), ('c1', 990, true)]);
      recorder.report(_p(0, unit: 'c2', title: '第二章'));
      expect(history.writes.last, ('c1', 900, false));
      recorder.flush();
      expect(history.writes.last, ('c2', 0, false));
    });
  });
}
