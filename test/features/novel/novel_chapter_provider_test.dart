import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/storage/app_database.dart';
import 'package:tsumugi/shared/novel/novel_chapter_loader.dart';
import 'package:tsumugi/shared/novel/novel_document.dart';
import 'package:tsumugi/features/novel/reader/novel_reader_providers.dart';
import 'package:tsumugi/sources/model/common.dart';
import 'package:tsumugi/sources/model/content.dart';
import 'package:tsumugi/sources/registry/providers.dart';
import 'package:tsumugi/sources/source.dart';

import '../../core/storage/test_database.dart';
import '../../core/network/mock_support.dart';
import '../../sources/runtime/runtime_support.dart';

const _mockId = 'com.example.mock.novel.declarative';

void main() {
  late AppDatabase db;
  late SourceRegistry registry;
  late ProviderContainer container;

  setUp(() {
    db = openTestDatabase();
    registry = SourceRegistry(db);
  });
  tearDown(() async {
    container.dispose();
    await db.close();
  });

  /// 读取正文，并在读取期间保持 provider 存活。
  Future<NovelChapter> chapter(String sourceId, String itemId, String unitId) {
    final p = novelReaderChapterProvider(sourceId, itemId, unitId);
    container.listen(p, (_, _) {});
    return container.read(p.future);
  }

  group('mock_server（声明式源）', () {
    late MockServer server;
    setUp(() async => server = await MockServer.start());
    tearDown(() => server.close());

    test('按 nextPageId 拉取章节内第二页并拼接', () async {
      await registry.importText(
        File('test/fixtures/sources/mock_novel_declarative.json')
            .readAsStringSync(),
      );
      container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          sourceFactoriesProvider.overrideWithValue(mockFactories(server)),
        ],
      );
      final c = await chapter(
        _mockId,
        '/novel/book/1',
        '/novel/book/1/chapter/1',
      );
      expect(c.blocks.map((b) => b.plainText), [
        '青石巷尽头有一家很小的钟表铺。',
        '这天傍晚，一位客人送来一只怀表。',
        '表针在灯下缓缓地倒着走。',
        '老人笑了笑，没有去修它。',
      ]);
      expect(server.hits('/novel/book/1/chapter/1'), 2);
    });
  });

  group('分页终止条件', () {
    late List<String> fetched;

    var created = false;
    void setUpSource(Map<String, NovelContent> pages) {
      if (created) container.dispose();
      created = true;
      fetched = [];
      container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          sourceFactoriesProvider.overrideWithValue(
            SourceFactories([
              FakeFactory(
                (m) => FakeSource(
                  m,
                  onDetail: (id) async => Detail(
                    id: id,
                    title: '书',
                    units: const [
                      Unit(id: 'c1', title: '一'),
                      Unit(id: 'c2', title: '二'),
                    ],
                  ),
                  onContent: (id) async {
                    fetched.add(id);
                    return pages[id] ??
                        (throw const SourceException(SourceErrorCode.http));
                  },
                ),
              ),
            ]),
          ),
        ],
      );
    }

    setUp(
      () => registry.importText(fakeManifestJson('s', type: MediaType.novel)),
    );

    test('“下一页”指向下一章时停止', () async {
      setUpSource({
        'c1': const NovelContent(text: '甲', nextPageId: 'c1-2'),
        'c1-2': const NovelContent(text: '乙', nextPageId: 'c2'),
        'c2': const NovelContent(text: '不应拼接'),
      });
      final c = await chapter('s', 'book', 'c1');
      expect(c.plainText, '甲\n乙');
      expect(fetched, ['c1', 'c1-2']);
    });

    test('循环的 nextPageId 不会死循环', () async {
      setUpSource({
        'c1': const NovelContent(text: '甲', nextPageId: 'p2'),
        'p2': const NovelContent(text: '乙', nextPageId: 'c1'),
      });
      final c = await chapter('s', 'book', 'c1');
      expect(c.plainText, '甲\n乙');
      expect(fetched, ['c1', 'p2']);
    });

    test('最多拼接 100 页', () async {
      setUpSource({
        for (var i = 0; i < 150; i++)
          'c1${i == 0 ? '' : '-$i'}': NovelContent(
            text: '$i',
            nextPageId: 'c1-${i + 1}',
          ),
      });
      final c = await chapter('s', 'book', 'c1');
      expect(c.blocks, hasLength(maxNovelChapterPages));
      expect(fetched, hasLength(maxNovelChapterPages));
    });

    test('html 页按白名单清洗；后续分页失败时整章报错', () async {
      setUpSource({
        'c1': const NovelContent(
          text: '<p>甲<script>x()</script></p>',
          html: true,
          nextPageId: 'gone',
        ),
      });
      await expectLater(
        chapter('s', 'book', 'c1'),
        throwsA(isA<SourceException>()),
      );
      setUpSource({
        'c1': const NovelContent(
          text: '<p>甲<script>x()</script></p>',
          html: true,
        ),
      });
      expect((await chapter('s', 'book', 'c1')).plainText, '甲');
    });
  });
}
