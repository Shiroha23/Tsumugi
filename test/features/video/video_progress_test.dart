import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/storage/app_database.dart';
import 'package:tsumugi/features/video/player/video_progress.dart';
import 'package:tsumugi/shared/history/history_repository.dart';
import 'package:tsumugi/shared/library/library_item.dart';
import 'package:tsumugi/shared/library/library_repository.dart';
import 'package:tsumugi/sources/model/common.dart';

import '../../core/storage/test_database.dart';

typedef _Write = (String unitId, int? position, bool markRead);

class _FakeHistory implements HistoryRepository {
  final writes = <_Write>[];

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

const _item = LibraryItem(
  sourceId: 's',
  itemId: 'i',
  title: 't',
  mediaType: MediaType.video,
);

VideoPlaybackProgress _p(
  int seconds, {
  String unit = 'e1',
  bool finished = false,
}) => VideoPlaybackProgress(
  item: _item,
  unitId: unit,
  unitTitle: unit,
  position: Duration(seconds: seconds),
  finished: finished,
);

void main() {
  group('VideoProgressRecorder', () {
    late _FakeHistory history;

    VideoProgressRecorder recorder(FakeAsync async) => VideoProgressRecorder(
      history: history,
      clock: () => async.getClock(DateTime(2026)).now(),
    );

    setUp(() => history = _FakeHistory());

    test('首次立即写入（毫秒）；间隔内只在到期时写入最新一次', () {
      fakeAsync((async) {
        final r = recorder(async);
        r.report(_p(1));
        expect(history.writes, [('e1', 1000, false)]);
        async.elapse(const Duration(seconds: 1));
        r.report(_p(2));
        r.report(_p(3));
        expect(history.writes, hasLength(1));
        async.elapse(const Duration(seconds: 4));
        expect(history.writes, [('e1', 1000, false), ('e1', 3000, false)]);
      });
    });

    test('immediate（暂停 / 离开页面）立即写入，并取消待写', () {
      fakeAsync((async) {
        final r = recorder(async);
        r.report(_p(1));
        r.report(_p(2));
        r.report(_p(3), immediate: true);
        expect(history.writes.map((w) => w.$2), [1000, 3000]);
        async.elapse(const Duration(seconds: 10));
        expect(history.writes, hasLength(2));
      });
    });

    test('换集时先写入上一集的待写进度', () {
      fakeAsync((async) {
        final r = recorder(async);
        r.report(_p(1));
        r.report(_p(4));
        r.report(_p(0, unit: 'e2'));
        expect(history.writes, [('e1', 1000, false), ('e1', 4000, false)]);
        async.elapse(const Duration(seconds: 5));
        expect(history.writes.last, ('e2', 0, false));
      });
    });

    test('第一次看完立即写入：标记已读、位置记为 0', () {
      fakeAsync((async) {
        final r = recorder(async);
        r.report(_p(1));
        r.report(_p(6, finished: true));
        expect(history.writes.last, ('e1', 0, true));
        // 之后同一集的“看完”照常节流。
        r.report(_p(6, finished: true));
        expect(history.writes, hasLength(2));
      });
    });

    test('flush 写入所有待写进度', () {
      fakeAsync((async) {
        final r = recorder(async);
        r.report(_p(1));
        r.report(_p(2));
        r.flush();
        expect(history.writes.map((w) => w.$2), [1000, 2000]);
        async.elapse(const Duration(seconds: 10));
        expect(history.writes, hasLength(2));
      });
    });
  });

  group('videoItemSnapshot（#24：不覆盖封面请求头）', () {
    late AppDatabase db;
    late LibraryRepository library;
    late HistoryRepository historyRepo;

    setUp(() {
      db = openTestDatabase();
      library = LibraryRepository(db);
      historyRepo = HistoryRepository(db);
    });
    tearDown(() => db.close());

    const cover = 'http://x.example.com/c.jpg';
    const detail = Detail(id: 'i', title: '新标题', cover: cover);
    const sourceHeaders = {'Referer': 'http://x.example.com/'};

    LibraryItem known(String cover, Headers headers) => LibraryItem(
      sourceId: 's',
      itemId: 'i',
      title: '旧',
      mediaType: MediaType.video,
      cover: cover,
      coverHeaders: headers,
    );

    Future<LibraryItem> snapshot([Detail d = detail]) => videoItemSnapshot(
      library: library,
      history: historyRepo,
      sourceId: 's',
      itemId: 'i',
      detail: d,
      sourceHeaders: sourceHeaders,
    );

    test('优先沿用书架条目的 headers', () async {
      await library.add(known(cover, {'X-Lib': '1'}));
      await historyRepo.recordProgress(
        known(cover, {'X-History': '1'}),
        unitId: 'e1',
        unitTitle: 'e1',
      );
      final item = await snapshot();
      expect(item.title, '新标题');
      expect(item.mediaType, MediaType.video);
      expect(item.coverHeaders, {'X-Lib': '1'});
    });

    test('其次沿用已有历史的 headers；写入后不会被清空', () async {
      await historyRepo.recordProgress(
        known(cover, {'X-Search': '1'}),
        unitId: 'e1',
        unitTitle: 'e1',
      );
      final item = await snapshot();
      expect(item.coverHeaders, {'X-Search': '1'});
      await historyRepo.recordProgress(item, unitId: 'e1', unitTitle: 'e1');
      final latest = await historyRepo.latestProgress('s', 'i');
      expect(latest!.item.coverHeaders, {'X-Search': '1'});
    });

    test('封面地址变了或没有记录时回退到源清单的 headers', () async {
      await library.add(known('http://x.example.com/old.jpg', {'X-Lib': '1'}));
      expect((await snapshot()).coverHeaders, sourceHeaders);
      expect(
        (await snapshot(const Detail(id: 'i', title: 't'))).coverHeaders,
        isNull,
        reason: '没有封面',
      );
    });
  });
}
