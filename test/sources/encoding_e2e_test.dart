import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/encoding/charset_sniffing.dart';
import 'package:tsumugi/core/network/dio_source_http_client.dart';
import 'package:tsumugi/core/network/source_http_client.dart';
import 'package:tsumugi/sources/declarative/declarative_source_factory.dart';
import 'package:tsumugi/sources/model/content.dart';
import 'package:tsumugi/sources/model/manifest.dart';
import 'package:tsumugi/sources/network_error_mapping.dart';
import 'package:tsumugi/sources/runtime/source_runtime.dart';
import 'package:tsumugi/sources/source.dart';

import '../core/network/mock_support.dart';

/// mock 服务器上 GBK / Big5 编码的虚构页面，经真实的 HTTP 客户端与声明式引擎解码。
void main() {
  late MockServer server;
  setUpAll(() async => server = await MockServer.start());
  tearDownAll(() => server.close());

  group('NetResponse（mock 服务器）', () {
    late SourceHttpClient http;
    setUp(() => http = mockClient(server, baseUrl: 'http://novel.example.com'));
    tearDown(() => http.close());

    Future<NetResponse> get(String path) => http.request(NetRequest(path));

    test('GBK：只靠 <meta http-equiv>（gb2312 标签）', () async {
      final r = await get('/gbk/search?q=x');
      expect(r.header('content-type'), isNot(contains('charset')));
      expect(r.charset.encoding, 'gb18030');
      expect(r.charset.source, CharsetSource.meta);
      expect(r.text, contains('<a href="/gbk/book/1">雾港旧事</a>'));
      expect(r.text, contains('虚构作者堃')); // GB2312 之外的字
    });

    test('GBK：Content-Type 带 charset', () async {
      final r = await get('/gbk/book/1/chapter/1');
      expect(r.charset.source, CharsetSource.header);
      expect(r.text, contains('雾从海面漫上来'));
    });

    test('Big5：Content-Type 带 charset / 只靠 <meta>', () async {
      final header = await get('/big5/book/1');
      expect(header.charset.source, CharsetSource.header);
      final meta = await get('/big5/book/1/meta-only');
      expect(meta.charset.source, CharsetSource.meta);
      for (final r in [header, meta]) {
        expect(r.charset.encoding, 'big5');
        expect(r.text, contains('<h1>霧港舊事</h1>'));
        expect(r.text, contains('燈塔看守人在霧裡撿到一封沒有地址的信。'));
      }
    });

    test('响应头错误声明 utf-8 时可显式指定 charset', () async {
      final r = await get('/gbk/mislabeled/chapter/1');
      expect(r.charset.source, CharsetSource.header);
      expect(r.text, contains('�'));
      expect(r.decodeText(charset: 'gbk'), contains('雾从海面漫上来'));
      expect(() => r.decodeText(charset: 'nope'), throwsArgumentError);
    });

    test('原始字节不受影响', () async {
      final r = await get('/gbk/book/1/chapter/1');
      expect(
        r.bytes,
        File('test/fixtures/mock_site/encoding/gbk/chapter_1.html')
            .readAsBytesSync(),
      );
    });
  });

  group('声明式源（mock_novel_gbk.json）', () {
    final created = <DisposableSource>[];
    tearDown(() {
      for (final s in created) {
        s.dispose();
      }
      created.clear();
    });

    Map<String, dynamic> manifestJson() => jsonDecode(
      File('test/fixtures/sources/mock_novel_gbk.json').readAsStringSync(),
    ) as Map<String, dynamic>;

    Future<Source> open(Map<String, dynamic> json) async {
      final factory = DeclarativeSourceFactory(
        httpClientFor: (m) => DioSourceHttpClient(
          networkConfigFromManifest(m),
          adapter: mockAdapter(server),
        ),
        scriptRuntimeFactory: null,
        log: (_) {},
      );
      final source = await factory.create(SourceManifest.fromJson(json));
      if (source is DisposableSource) created.add(source);
      return source;
    }

    test('搜索 → 详情 → 正文 得到正确的中文', () async {
      final source = await open(manifestJson());

      final page = await source.search('雾', 1);
      expect(page.items.map((i) => i.title), ['雾港旧事', '纸鸢与铜铃']);
      expect(page.items.first.subtitle, '虚构作者堃');
      expect(page.items.first.tags, ['已完结']);

      final detail = await source.detail('/gbk/book/1');
      expect(detail.title, '雾港旧事');
      expect(detail.author, '虚构作者堃');
      expect(detail.description, '灯塔看守人在雾里捡到一封没有地址的信。');
      expect(detail.units.map((u) => u.title), ['第一章 无名信', '第二章 灯塔']);

      final content =
          await source.content('/gbk/book/1/chapter/2') as NovelContent;
      expect(content.text, contains('信里只写着一句话：「明天的雾会散。」'));
    });

    test('request.charset 覆盖错误的响应头', () async {
      final json = manifestJson();
      final plain = await open(
        json,
      ).then((s) => s.content('/gbk/mislabeled/chapter/1')) as NovelContent;
      expect(plain.text, contains('�'));

      (json['rules'] as Map<String, dynamic>)['content'] = {
        'request': {'url': '{{unitId}}', 'charset': 'GBK'},
        'text': 'css:#content p@text[]',
      };
      final fixed = await open(
        json,
      ).then((s) => s.content('/gbk/mislabeled/chapter/1')) as NovelContent;
      expect(fixed.text, contains('雾从海面漫上来，把整座港口裹进一团灰白里。'));
    });

    test('不支持的 request.charset → E_PARSE', () async {
      final json = manifestJson();
      (json['rules'] as Map<String, dynamic>)['content'] = {
        'request': {'url': '{{unitId}}', 'charset': 'euc-jp'},
        'text': 'css:#content p@text[]',
      };
      await expectLater(
        open(json),
        throwsA(
          isA<SourceException>()
              .having((e) => e.code, 'code', SourceErrorCode.parse)
              .having((e) => e.message, 'message', contains('charset')),
        ),
      );
    });
  });
}
