import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/engine/declarative/fetcher.dart';
import 'package:tsumugi/core/engine/script/quickjs_script_runtime.dart';
import 'package:tsumugi/sources/declarative/declarative_source.dart';
import 'package:tsumugi/sources/model/common.dart';
import 'package:tsumugi/sources/model/content.dart';
import 'package:tsumugi/sources/source.dart';

import 'fixture_fetcher.dart';

Matcher throwsSource(SourceErrorCode code, {int? status}) => throwsA(
  isA<SourceException>()
      .having((e) => e.code, 'code', code)
      .having((e) => e.status, 'status', status),
);

void main() {
  late List<String> logs;
  setUp(() => logs = []);

  group('comic: search → detail → content', () {
    const base = 'https://comic.example.com';
    final q = Uri.encodeComponent('星之');
    late FixtureFetcher fetcher;
    late DeclarativeSource source;

    setUp(() {
      fetcher = FixtureFetcher({
        'GET $base/search?q=$q&page=1': 'comic/search.html',
        'GET $base/search?q=$q&page=2': 'comic/search_last.html',
        'GET $base/latest?page=1': 'comic/latest.html',
        'GET $base/comic/101/': 'comic/detail.html',
        'GET $base/comic/101/1.html?quality=low': 'comic/chapter_1.html',
      });
      source = DeclarativeSource(
        manifest: loadManifest('comic'),
        fetcher: fetcher,
        settings: {'quality': 'low'},
        log: logs.add,
      );
    });

    test('end to end', () async {
      final page = await source.search('星之', 1);
      expect(page.hasMore, isTrue);
      expect(page.items, hasLength(2));
      final first = page.items.first;
      expect(first.id, '/comic/101/');
      expect(first.title, '星之旅人');
      expect(first.cover, '$base/covers/101.jpg');
      expect(first.coverHeaders, {'Referer': '$base/'});
      expect(first.subtitle, '作者甲');
      expect(first.tags, ['冒险', '科幻']);
      expect(page.items[1].cover, 'https://img.example.com/covers/102.jpg');
      expect(page.items[1].subtitle, isNull);
      expect(page.items[1].tags, isEmpty);
      expect(logs, contains(contains('跳过')));
      // 默认 headers 随请求发送。
      expect(fetcher.requests.single.headers['Referer'], '$base/');

      final last = await source.search('星之', 2);
      expect(last.items, isEmpty);
      expect(last.hasMore, isFalse);

      final detail = await source.detail(first.id);
      expect(detail.id, '/comic/101/');
      expect(detail.title, '星之旅人');
      expect(detail.cover, '$base/covers/101_large.jpg');
      expect(detail.author, '作者甲');
      expect(detail.description, '一段虚构的简介。');
      expect(detail.tags, ['冒险', '科幻']);
      expect(detail.status, SeriesStatus.ongoing);
      expect(detail.updatedAt, '2026-10-01');
      // reverse: true
      expect(detail.units.map((u) => u.title), ['第1话', '第2话', '第3话']);
      expect(detail.units.map((u) => u.index), [0, 1, 2]);
      expect(detail.units.first.id, '/comic/101/1.html');
      expect(detail.units.last.updatedAt, '2026-10-01');

      final content = await source.content(detail.units.first.id);
      expect(content, isA<ComicContent>());
      final images = (content as ComicContent).images;
      expect(images.map((i) => i.url), [
        '$base/img/101/1/001.jpg',
        'https://img.example.com/101/1/002.jpg',
        'https://img.example.com/101/1/003.jpg',
      ]);
      expect(images.first.headers, {'Referer': '$base/'});
    });

    test('explore', () async {
      final categories = await source.explore();
      expect(categories.single.name, '最新');
      final page = await source.exploreList(categories.single.id, 1);
      expect(page.items.map((i) => (i.id, i.title)), [
        ('/comic/201/', '新作一'),
        ('/comic/202/', '新作二'),
      ]);
      expect(page.hasMore, isFalse);
      expect(
        () => source.exploreList('9', 1),
        throwsSource(SourceErrorCode.unsupported),
      );
    });

    test('setting default is used when not set', () async {
      final s = DeclarativeSource(
        manifest: loadManifest('comic'),
        fetcher: fetcher,
      );
      await expectLater(
        s.content('/comic/101/1.html'),
        throwsSource(SourceErrorCode.http, status: 404),
      );
      expect(
        fetcher.requests.last.url.toString(),
        '$base/comic/101/1.html?quality=high',
      );
    });

    test('hosts outside the allow list are refused', () async {
      await expectLater(
        source.detail('https://evil.example.org/comic/1'),
        throwsSource(SourceErrorCode.hostNotAllowed),
      );
      expect(fetcher.requests, isEmpty);
      // allowedHosts 中的主机可以访问（这里返回 404）。
      await expectLater(
        source.detail('https://img.example.com/x'),
        throwsSource(SourceErrorCode.http, status: 404),
      );
    });
  });

  group('novel: search → detail → content (with js:)', () {
    const base = 'https://novel.example.com';
    late FixtureFetcher fetcher;
    late DeclarativeSource source;

    setUp(() {
      fetcher = FixtureFetcher({
        'POST $base/api/search': 'novel/search.json',
        'GET $base/book/7/': 'novel/book.html',
        'GET $base/book/7/1.html': 'novel/chapter_1.html',
        'GET $base/book/7/1_2.html': 'novel/chapter_1_2.html',
      });
      source = DeclarativeSource(
        manifest: loadManifest('novel'),
        fetcher: fetcher,
        scriptRuntimeFactory: QuickJsScriptRuntime.create,
        log: logs.add,
      );
    });
    tearDown(() => source.dispose());

    test('end to end', () async {
      final page = await source.search('雾 港', 1);
      final req = fetcher.requests.single;
      expect(req.method, 'POST');
      expect(req.body, 'q=${Uri.encodeComponent('雾 港')}&p=1');
      expect(req.headers['Content-Type'], startsWith('application/x-www-form'));
      expect(req.headers['User-Agent'], 'Tsumugi-Test');
      expect(page.hasMore, isFalse);
      expect(page.items.map((i) => i.title), ['雾港往事', '雾港往事·续']);
      expect(page.items.first.cover, '$base/cover/7.jpg');
      expect(page.items.first.tags, ['悬疑', '都市']);
      expect(page.items[1].cover, isNull);

      final detail = await source.detail(page.items.first.id);
      expect(detail.title, '雾港往事');
      expect(detail.author, '作者乙');
      expect(detail.description, '第一段简介。\n第二段简介。');
      expect(detail.status, SeriesStatus.completed);
      expect(detail.tags, ['悬疑', '都市']);
      expect(detail.units.map((u) => u.id), [
        '/book/7/1.html',
        '/book/7/2.html',
      ]);

      // 章节内分页：nextPageId 作为下一次 content 的 unitId。
      final p1 = await source.content(detail.units.first.id) as NovelContent;
      // @text 去首尾空白（含全角空格），段落缩进交给阅读器排版。
      expect(p1.text, '雾从海面上漫过来。\n灯塔亮了。');
      expect(p1.html, isFalse);
      expect(p1.nextPageId, '/book/7/1_2.html');
      final p2 = await source.content(p1.nextPageId!) as NovelContent;
      expect(p2.text, '（本章完）');
      expect(p2.nextPageId, isNull);
      expect(logs, isEmpty);
    });

    test('without a script runtime js: steps are empty', () async {
      final s = DeclarativeSource(
        manifest: loadManifest('novel'),
        fetcher: fetcher,
        log: logs.add,
      );
      final detail = await s.detail('/book/7/');
      expect(detail.description, isNull);
      expect(detail.status, SeriesStatus.unknown);
      expect(logs.first, contains('未提供脚本运行时'));
    });
  });

  test('video content', () async {
    final source = DeclarativeSource(
      manifest: loadManifest('video'),
      fetcher: FixtureFetcher({
        'GET https://video.example.com/play/e1': 'video/play.html',
      }),
    );
    final content = await source.content('e1') as VideoContent;
    expect(content.streams.map((s) => (s.url, s.type)), [
      ('https://media.example-cdn.com/e1/index.m3u8', StreamType.hls),
      ('https://video.example.com/files/e1.mp4', StreamType.mp4),
      ('https://video.example.com/files/e1.mpd', StreamType.dash),
      ('https://video.example.com/files/e1.flv', StreamType.auto),
    ]);
    expect(content.streams.first.headers, isNull);
    expect(content.subtitles, isEmpty);
    expect(
      () => source.search('x', 1),
      throwsSource(SourceErrorCode.unsupported),
    );
    expect(() => source.explore(), throwsSource(SourceErrorCode.unsupported));
  });

  test('music content', () async {
    final source = DeclarativeSource(
      manifest: loadManifest('music'),
      fetcher: FixtureFetcher({
        'GET https://music.example.com/api/song?id=s1': 'music/song.json',
      }),
    );
    final content = await source.content('s1') as MusicContent;
    expect(content.streams.map((s) => s.url), [
      'https://music.example.com/audio/s1.flac',
      'https://music.example.com/audio/s1.mp3',
    ]);
    expect(content.streams.first.headers, {
      'Referer': 'https://music.example.com/',
    });
    expect(content.lyrics?.format, LyricsFormat.lrc);
    expect(content.lyrics?.content, startsWith('[00:00.00]'));
  });

  group('errors', () {
    test('fetcher exceptions keep their code', () async {
      final source = DeclarativeSource(
        manifest: loadManifest('music'),
        fetcher: _ThrowingFetcher(
          const FetchException('E_CHALLENGE', 'cf', 503),
        ),
      );
      await expectLater(
        source.content('s1'),
        throwsSource(SourceErrorCode.challenge, status: 503),
      );
    });

    test('other fetcher errors become E_NETWORK', () async {
      final source = DeclarativeSource(
        manifest: loadManifest('music'),
        fetcher: _ThrowingFetcher(StateError('socket closed')),
      );
      await expectLater(
        source.content('s1'),
        throwsSource(SourceErrorCode.network),
      );
    });

    test('malformed rules are E_PARSE', () {
      final manifest = loadManifest('music').copyWith(
        rules: {
          'search': {'list': 'css:a', 'fields': {}},
        },
      );
      expect(
        () =>
            DeclarativeSource(manifest: manifest, fetcher: FixtureFetcher({})),
        throwsSource(SourceErrorCode.parse),
      );
    });

    test('script manifests are rejected', () {
      final manifest = loadManifest('music')
          .copyWith(engine: SourceEngine.script, script: 'export {}');
      expect(
        () =>
            DeclarativeSource(manifest: manifest, fetcher: FixtureFetcher({})),
        throwsSource(SourceErrorCode.unsupported),
      );
    });
  });
}

class _ThrowingFetcher implements Fetcher {
  _ThrowingFetcher(this.error);
  final Object error;
  @override
  Future<FetchResponse> fetch(FetchRequest request) async => throw error;
}
