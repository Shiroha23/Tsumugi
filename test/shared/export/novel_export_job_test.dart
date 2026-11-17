import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/shared/export/novel_export_job.dart';
import 'package:tsumugi/core/network/rate_limiter.dart';
import 'package:tsumugi/core/network/source_session.dart';
import 'package:tsumugi/shared/export/export_models.dart';
import 'package:tsumugi/shared/image/source_image_loader.dart';
import 'package:tsumugi/sources/model/common.dart';
import 'package:tsumugi/sources/model/content.dart';
import 'package:tsumugi/sources/model/manifest.dart';
import 'package:tsumugi/sources/registry/source_registry.dart';
import 'package:tsumugi/sources/runtime/source_runtime.dart';
import 'package:tsumugi/sources/source.dart';

import '../../core/network/mock_support.dart';
import '../../core/storage/test_database.dart';
import '../../sources/runtime/runtime_support.dart';

const _sourceId = 'com.example.novel';

final _manifest = SourceManifest.fromJson(
  jsonDecode(fakeManifestJson(_sourceId, name: '小说源', type: MediaType.novel))
      as Map<String, dynamic>,
);

const _detail = Detail(
  id: '/book/1',
  title: '雾港/夜航?',
  author: '虚构作者',
  cover: 'https://example.com/cover.png',
  units: [
    Unit(id: 'c1', title: '第一章'),
    Unit(id: 'c2', title: '第二章'),
    Unit(id: 'c3', title: '第三章'),
  ],
);

/// 1×1 透明 PNG。
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
);

const _network = SourceException(SourceErrorCode.network, 'timeout');
const _challenge = SourceException(SourceErrorCode.challenge);

NovelExportJob _job(
  Source source, {
  ExportFormat format = ExportFormat.txt,
  List<Unit>? units,
  ExportImageLoader? loadImage,
  int maxImageBytes = NovelExportJob.defaultMaxImageBytes,
  int maxTotalImageBytes = NovelExportJob.defaultMaxTotalImageBytes,
}) => NovelExportJob(
  request: NovelExportRequest(
    sourceId: _sourceId,
    itemId: _detail.id,
    detail: _detail,
    units: units ?? _detail.units,
    format: format,
  ),
  sourceFor: (_) async => source,
  loadImage: loadImage,
  clock: () => DateTime(2026, 11, 13, 9),
  buildInIsolate: false,
  maxImageBytes: maxImageBytes,
  maxTotalImageBytes: maxTotalImageBytes,
);

String _chapterXhtml(ExportFile file, int n) => utf8.decode(
  ZipDecoder()
          .decodeBytes(file.bytes)
          .findFile('OEBPS/chapter-${n.toString().padLeft(4, '0')}.xhtml')!
          .content
      as List<int>,
);

List<String> _imageEntries(ExportFile file) => [
  for (final f in ZipDecoder().decodeBytes(file.bytes).files)
    if (f.name.startsWith('OEBPS/images/')) f.name,
];

/// 等待 [job] 进入 [phase]。
Future<void> _until(NovelExportJob job, ExportPhase phase) async {
  if (job.status.phase == phase) return;
  final c = Completer<void>();
  void listener() {
    if (job.status.phase == phase && !c.isCompleted) c.complete();
  }

  job.addListener(listener);
  await c.future.timeout(const Duration(seconds: 5));
  job.removeListener(listener);
}

void main() {
  test('逐章顺序取正文（含章节内分页），不并发；生成的 TXT 含全部章节', () async {
    final calls = <String>[];
    var inFlight = 0;
    var maxInFlight = 0;
    final source = FakeSource(
      _manifest,
      onContent: (id) async {
        calls.add(id);
        inFlight++;
        maxInFlight = inFlight > maxInFlight ? inFlight : maxInFlight;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        inFlight--;
        return switch (id) {
          'c1' => const NovelContent(text: '一页一', nextPageId: 'c1?p=2'),
          'c1?p=2' => const NovelContent(text: '一页二', nextPageId: 'c2'),
          _ => NovelContent(text: '$id 正文'),
        };
      },
    );
    final job = _job(source);
    final progress = <(ExportPhase, int)>[];
    job.addListener(
      () => progress.add((job.status.phase, job.status.completed)),
    );
    final file = await job.run();

    // “下一页”等于下一章的 id 时停止拼接。
    expect(calls, ['c1', 'c1?p=2', 'c2', 'c3']);
    expect(maxInFlight, 1);
    expect(progress, [
      (ExportPhase.fetching, 0),
      (ExportPhase.fetching, 1),
      (ExportPhase.fetching, 2),
      (ExportPhase.building, 3),
      (ExportPhase.done, 3),
    ]);
    expect(file!.fileName, '雾港_夜航_.txt');
    expect(file.format, ExportFormat.txt);
    final text = utf8.decode(file.bytes);
    expect(text, contains('来源：小说源\n'));
    expect(text, contains('第一章\n\n　　一页一\n　　一页二\n'));
    expect(text, contains('第三章\n\n　　c3 正文\n'));
    expect(job.status.failures, isEmpty);
  });

  test('单章失败时暂停：重试成功；跳过的章节列在结果与文件头部', () async {
    var c2Attempts = 0;
    final source = FakeSource(
      _manifest,
      onContent: (id) async {
        if (id == 'c2' && c2Attempts++ == 0) throw _network;
        if (id == 'c3') throw const SourceException(SourceErrorCode.parse);
        return NovelContent(text: '$id 正文');
      },
    );
    final job = _job(source);
    final result = job.run();

    await _until(job, ExportPhase.paused);
    expect(job.status.current?.id, 'c2');
    expect(job.status.error, _network);
    expect(job.status.completed, 1);
    job.retry();

    await _until(job, ExportPhase.paused);
    expect(job.status.current?.id, 'c3');
    job.skip();

    final file = await result;
    expect(c2Attempts, 2);
    expect(job.status.phase, ExportPhase.done);
    expect([for (final f in job.status.failures) f.unit.id], ['c3']);
    final text = utf8.decode(file!.bytes);
    expect(text, contains('以下 1 章导出失败，未包含在本文件中：\n　　第三章\n'));
    expect(text, contains('c2 正文'));
    expect(text, isNot(contains('c3 正文')));
  });

  test('“跳过所有失败章节”后普通失败自动跳过，需要验证时仍暂停，验证后可继续', () async {
    var verified = false;
    final source = FakeSource(
      _manifest,
      onContent: (id) async => switch (id) {
        'c1' => throw _network,
        'c2' => throw _network,
        _ when !verified => throw _challenge,
        _ => NovelContent(text: '$id 正文'),
      },
    );
    final job = _job(source);
    final result = job.run();
    await _until(job, ExportPhase.paused);
    expect(job.status.current?.id, 'c1');
    job.skip(all: true);

    await _until(job, ExportPhase.paused);
    expect(job.status.current?.id, 'c3', reason: 'c2 应自动跳过');
    expect(job.status.error, _challenge);
    // 用户在验证页完成验证后重试。
    verified = true;
    job.retry();

    final file = await result;
    expect([for (final f in job.status.failures) f.unit.id], ['c1', 'c2']);
    expect(utf8.decode(file!.bytes), contains('c3 正文'));
  });

  test('取消：进行中的请求结果被丢弃，不再请求后续章节', () async {
    final calls = <String>[];
    final hang = Completer<MediaContent>();
    final source = FakeSource(
      _manifest,
      onContent: (id) {
        calls.add(id);
        return id == 'c1'
            ? Future.value(const NovelContent(text: '一'))
            : hang.future;
      },
    );
    final job = _job(source);
    final result = job.run();
    await _until(job, ExportPhase.fetching);
    while (calls.length < 2) {
      await Future<void>.delayed(Duration.zero);
    }
    job.cancel();
    expect(await result, isNull);
    expect(job.status.phase, ExportPhase.cancelled);
    expect(job.status.completed, 1);
    hang.complete(const NovelContent(text: '迟到的'));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(calls, ['c1', 'c2']);
    expect(job.status.phase, ExportPhase.cancelled);
  });

  test('暂停时取消', () async {
    final source = FakeSource(
      _manifest,
      onContent: (_) async => throw _network,
    );
    final job = _job(source);
    final result = job.run();
    await _until(job, ExportPhase.paused);
    job.cancel();
    expect(await result, isNull);
    expect(job.status.phase, ExportPhase.cancelled);
  });

  test('全部章节失败（都跳过）时导出失败', () async {
    final source = FakeSource(
      _manifest,
      onContent: (_) async => throw _network,
    );
    final job = _job(source);
    final result = job.run();
    await _until(job, ExportPhase.paused);
    job.skip(all: true);
    await expectLater(result, throwsA(isA<NothingToExportException>()));
    expect(job.status.phase, ExportPhase.failed);
    expect(job.status.failures, hasLength(3));
  });

  test('EPUB：封面经图片加载嵌入；加载失败则不放封面', () async {
    final source = FakeSource(
      _manifest,
      onContent: (id) async => NovelContent(text: '<p>$id</p>', html: true),
    );
    final requested = <(String, String)>[];
    final withCover = await _job(
      source,
      format: ExportFormat.epub,
      loadImage: (sourceId, url, _) async {
        requested.add((sourceId, url));
        return _png;
      },
    ).run();
    expect(requested, [(_sourceId, 'https://example.com/cover.png')]);
    expect(withCover!.fileName, '雾港_夜航_.epub');
    final a = ZipDecoder().decodeBytes(withCover.bytes);
    expect(a.findFile('OEBPS/cover.png'), isNotNull);
    expect(a.files.where((f) => f.name.contains('chapter-')), hasLength(3));

    final noCover = await _job(
      source,
      format: ExportFormat.epub,
      loadImage: (_, _, _) async => throw _network,
    ).run();
    final b = ZipDecoder().decodeBytes(noCover!.bytes);
    expect(b.findFile('OEBPS/cover.png'), isNull);
    expect(b.findFile('OEBPS/cover.xhtml'), isNull);
  });

  group('EPUB 正文图片（#25）', () {
    const img = 'https://img.example.com';
    // 第一章带四张图；第二章重复引用 a.png。
    final source = FakeSource(
      _manifest,
      onContent: (id) async => NovelContent(
        html: true,
        text: switch (id) {
          'c1' =>
            '<p>开头</p><img src="$img/a.png" alt="甲">'
                '<img src="$img/broken.png" alt="坏图">'
                '<img src="$img/big.png" alt="大图">'
                '<img src="$img/text.png" alt="非图片">',
          'c2' => '<p>又见</p><img src="$img/a.png" alt="甲">',
          _ => '<p>$id</p>',
        },
      ),
    );

    test('逐张下载并嵌入；同一地址只下载一次；失败 / 超限 / 非图片保留占位', () async {
      final requested = <String>[];
      final file = await _job(
        source,
        format: ExportFormat.epub,
        maxImageBytes: 1024,
        loadImage: (sourceId, url, _) async {
          expect(sourceId, _sourceId);
          requested.add(url);
          return switch (url) {
            '$img/a.png' || 'https://example.com/cover.png' => _png,
            '$img/big.png' => Uint8List(2048)..setAll(0, _png),
            '$img/text.png' => utf8.encode('<html>not an image</html>'),
            _ => throw _network,
          };
        },
      ).run();
      expect(requested, [
        'https://example.com/cover.png',
        '$img/a.png',
        '$img/broken.png',
        '$img/big.png',
        '$img/text.png',
      ]);
      expect(_imageEntries(file!), ['OEBPS/images/img-0001.png']);
      final c1 = _chapterXhtml(file, 1);
      expect(c1, contains('<img src="images/img-0001.png" alt="甲"/>'));
      expect(c1, contains('<p>［图片：坏图］</p>'));
      expect(c1, contains('<p>［图片：大图］</p>'));
      expect(c1, contains('<p>［图片：非图片］</p>'));
      expect(
        _chapterXhtml(file, 2),
        contains('<img src="images/img-0001.png" alt="甲"/>'),
      );
    });

    test('总大小达到上限后不再下载其余图片', () async {
      final requested = <String>[];
      final file = await _job(
        source,
        format: ExportFormat.epub,
        maxTotalImageBytes: _png.length,
        loadImage: (_, url, _) async {
          requested.add(url);
          return _png;
        },
      ).run();
      expect(requested, ['https://example.com/cover.png', '$img/a.png']);
      expect(_imageEntries(file!), ['OEBPS/images/img-0001.png']);
      expect(_chapterXhtml(file, 1), contains('<p>［图片：坏图］</p>'));
    });

    test('TXT 不下载封面与正文图片', () async {
      final requested = <String>[];
      await _job(
        source,
        loadImage: (_, url, _) async {
          requested.add(url);
          return _png;
        },
      ).run();
      expect(requested, isEmpty);
    });

    test('下载图片时取消：不生成文件', () async {
      final gate = Completer<Uint8List>();
      final job = _job(
        source,
        format: ExportFormat.epub,
        loadImage: (_, url, _) async =>
            url.endsWith('cover.png') ? _png : gate.future,
      );
      final result = job.run();
      await _until(job, ExportPhase.building);
      await Future<void>.delayed(Duration.zero);
      job.cancel();
      expect(await result, isNull);
      expect(job.status.phase, ExportPhase.cancelled);
    });
  });

  test('在后台 isolate 中生成文件', () async {
    final source = FakeSource(
      _manifest,
      onContent: (id) async => NovelContent(text: '$id 正文'),
    );
    final file = await NovelExportJob(
      request: NovelExportRequest(
        sourceId: _sourceId,
        itemId: _detail.id,
        detail: _detail,
        units: _detail.units,
        format: ExportFormat.epub,
      ),
      sourceFor: (_) async => source,
    ).run();
    expect(ZipDecoder().decodeBytes(file!.bytes).files.first.name, 'mimetype');
  });

  group('mock_server（声明式源）', () {
    late MockServer server;
    setUp(() async => server = await MockServer.start());
    tearDown(() => server.close());

    test('经源运行时取得实例：限速下按章节、分页顺序逐个请求', () async {
      final db = openTestDatabase();
      addTearDown(db.close);
      final registry = SourceRegistry(db);
      final manifest = jsonDecode(
        File('test/fixtures/sources/mock_novel_declarative.json')
            .readAsStringSync(),
      ) as Map<String, dynamic>;
      // 令牌桶：突发 1 个，之后每秒放行一个。
      manifest['rateLimit'] = {'requests': 1, 'perSeconds': 1};
      await registry.importText(jsonEncode(manifest));
      final runtime = SourceRuntime(registry, mockFactories(server));
      addTearDown(runtime.dispose);
      const id = 'com.example.mock.novel.declarative';
      final source = await runtime.get(id);
      final detail = await source.detail('/novel/book/1');
      expect(detail.units, hasLength(2));

      final sw = Stopwatch()..start();
      final file = await NovelExportJob(
        request: NovelExportRequest(
          sourceId: id,
          itemId: '/novel/book/1',
          detail: detail,
          units: detail.units,
          format: ExportFormat.txt,
        ),
        sourceFor: runtime.get,
        clock: () => DateTime(2026, 11, 13),
        buildInIsolate: false,
      ).run();
      sw.stop();

      expect(
        [
          for (final r in server.requests)
            '${r.path}${r.query.isEmpty ? '' : '?p=${r.query['p']}'}',
        ],
        [
          '/novel/book/1',
          '/novel/book/1/chapter/1',
          '/novel/book/1/chapter/1?p=2',
          '/novel/book/1/chapter/2',
        ],
      );
      // 详情之后的 3 次请求各需等待一个令牌（1 个 / 秒）。
      expect(sw.elapsed, greaterThan(const Duration(milliseconds: 2500)));
      final text = utf8.decode(file!.bytes);
      expect(text, contains('来源：Mock 小说（声明式）\n'));
      expect(
        text,
        contains(
          '第一章 倒走的怀表\n\n'
          '　　青石巷尽头有一家很小的钟表铺。\n'
          '　　这天傍晚，一位客人送来一只怀表。\n'
          '　　表针在灯下缓缓地倒着走。\n'
          '　　老人笑了笑，没有去修它。\n',
        ),
      );
      expect(text, contains('第二章 雨季\n\n　　雨季来的时候'));
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('EPUB 正文图片经统一图片加载：遵守该源的白名单、限速与 Cookie（#25）', () async {
      final session = SourceSession();
      await session.cookieJar.saveFromResponse(
        Uri.parse('http://img.example.com/'),
        [Cookie('sid', 'fictional')],
      );
      final client = mockClient(
        server,
        sourceId: _sourceId,
        baseUrl: 'http://novel.example.com',
        session: session,
        rateLimit: const RateLimitConfig(
          requests: 1,
          per: Duration(milliseconds: 600),
        ),
      );
      addTearDown(client.close);
      final images = SourceImageLoader(httpClientFor: (_) => client);
      final source = FakeSource(
        _manifest,
        onContent: (id) async => const NovelContent(
          html: true,
          text:
              '<img src="http://img.example.com/pages/1.png" alt="一">'
              '<img src="http://outside.example.net/pages/2.png" alt="域外">'
              '<img src="http://img.example.com/pages/3.png" alt="三">',
        ),
      );
      const unit = Unit(id: 'c1', title: '第一章');
      final sw = Stopwatch()..start();
      final file = await NovelExportJob(
        request: const NovelExportRequest(
          sourceId: _sourceId,
          itemId: '/book/1',
          detail: Detail(id: '/book/1', title: '雾港', units: [unit]),
          units: [unit],
          format: ExportFormat.epub,
        ),
        sourceFor: (_) async => source,
        loadImage: (sourceId, url, headers) =>
            images.load(sourceId, ImageRef(url: url, headers: headers)),
        clock: () => DateTime(2026, 11, 13, 9),
        buildInIsolate: false,
      ).run();
      sw.stop();

      // 白名单外的主机不发请求；其余两张依次经该源的客户端（限速 + Cookie）。
      expect(
        [for (final r in server.requests) '${r.host}${r.path}'],
        ['img.example.com/pages/1.png', 'img.example.com/pages/3.png'],
      );
      for (final r in server.requests) {
        expect(r.headers['cookie'], contains('sid=fictional'));
      }
      expect(sw.elapsed, greaterThan(const Duration(milliseconds: 500)));
      expect(_imageEntries(file!), [
        'OEBPS/images/img-0001.png',
        'OEBPS/images/img-0002.png',
      ]);
      final c1 = _chapterXhtml(file, 1);
      expect(c1, contains('<img src="images/img-0001.png" alt="一"/>'));
      expect(c1, contains('<p>［图片：域外］</p>'));
      expect(c1, contains('<img src="images/img-0002.png" alt="三"/>'));
    });

    test('GBK 编码的站点：导出得到正确的中文', () async {
      final db = openTestDatabase();
      addTearDown(db.close);
      final registry = SourceRegistry(db);
      await registry.importText(
        File('test/fixtures/sources/mock_novel_gbk.json').readAsStringSync(),
      );
      final runtime = SourceRuntime(registry, mockFactories(server));
      addTearDown(runtime.dispose);
      const id = 'com.example.mock.novel.gbk';
      final source = await runtime.get(id);
      final detail = await source.detail('/gbk/book/1');

      final file = await NovelExportJob(
        request: NovelExportRequest(
          sourceId: id,
          itemId: '/gbk/book/1',
          detail: detail,
          units: detail.units,
          format: ExportFormat.txt,
        ),
        sourceFor: runtime.get,
        clock: () => DateTime(2026, 11, 13),
        buildInIsolate: false,
      ).run();

      final text = utf8.decode(file!.bytes);
      expect(text, contains('雾港旧事'));
      expect(text, contains('作者：虚构作者堃'));
      expect(
        text,
        contains(
          '第一章 无名信\n\n'
          '　　雾从海面漫上来，把整座港口裹进一团灰白里。\n'
          '　　看守人老堃在台阶上捡到一封信，信封上一个字也没有。\n',
        ),
      );
      expect(text, contains('第二章 灯塔\n\n　　灯塔的光一圈一圈扫过海面。'));
      expect(text, isNot(contains('�')));
    });
  });
}
