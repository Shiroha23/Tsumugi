import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/storage/app_database.dart';
import 'package:tsumugi/shared/novel/novel_chapter_loader.dart';
import 'package:tsumugi/shared/novel/novel_document.dart';
import 'package:tsumugi/sources/registry/providers.dart';
import 'package:tsumugi/sources/runtime/source_runtime.dart';
import 'package:tsumugi/sources/source.dart';

import '../../core/network/mock_support.dart';
import '../../core/storage/test_database.dart';
import '../../sources/runtime/runtime_support.dart';

const _id = 'com.example.mock.novel.script';
const _manifest = 'test/fixtures/sources/mock_novel_script.json';

/// 带插图的虚构脚本小说源（下载 / 离线阅读的集成测试用）与 mock 服务器的断网开关。
void main() {
  test('清单内联的脚本与 test/fixtures/script/novel/source.js 一致', () {
    final json =
        jsonDecode(File(_manifest).readAsStringSync()) as Map<String, Object?>;
    expect(
      json['script'],
      File('test/fixtures/script/novel/source.js')
          .readAsStringSync()
          .replaceAll('\r\n', '\n'),
    );
  });

  group('经 mock 服务器', () {
    late AppDatabase db;
    late MockServer server;
    late ProviderContainer container;

    setUp(() async {
      db = openTestDatabase();
      server = await MockServer.start();
      await SourceRegistry(db).importText(File(_manifest).readAsStringSync());
      container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          sourceFactoriesProvider.overrideWithValue(mockFactories(server)),
        ],
      );
    });
    tearDown(() async {
      container.dispose();
      await server.close();
      await db.close();
    });

    test('详情 → 正文为带插图的受限 HTML，章节内分页拼接', () async {
      final source = await container.read(sourceInstanceProvider(_id).future);
      final detail = await source.detail('/novel/book/1');
      expect(detail.units.map((u) => u.title), ['第一章 倒走的怀表', '第二章 雨季']);

      final chapter = await loadNovelChapter(
        source,
        '/novel/book/1/chapter/1',
        unitIds: novelUnitIdsOf(detail),
      );
      expect(chapter.plainText, contains('一位客人送来一只怀表'));
      expect(
        chapter.blocks.whereType<NovelImage>().map((i) => (i.url, i.alt)),
        [
          ('http://img.example.com/static/novel/1-1.png', '插图 1-1'),
          ('http://img.example.com/static/novel/1-2.png', '插图 1-2'),
        ],
      );
    });

    test('断网后连接被直接断开', () async {
      final source = await container.read(sourceInstanceProvider(_id).future);
      server.offline = true;
      await expectLater(
        source.detail('/novel/book/1'),
        throwsA(
          isA<SourceException>().having(
            (e) => e.code,
            'code',
            SourceErrorCode.network,
          ),
        ),
      );
      expect(server.requests, isEmpty);
    });
  });
}
