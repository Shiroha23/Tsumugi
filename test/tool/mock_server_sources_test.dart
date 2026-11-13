import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/mock_server/mock_server.dart';

void main() {
  late MockServer server;
  late HttpClient client;

  setUp(() async {
    server = await MockServer.start();
    client = HttpClient();
  });
  tearDown(() async {
    client.close(force: true);
    await server.close();
  });

  Future<(int, String)> get(String path) async {
    final req = await client.getUrl(server.origin.resolve(path));
    final res = await req.close();
    return (res.statusCode, await utf8.decoder.bind(res).join());
  }

  test('虚构源中的固定地址被换成请求所用的地址', () async {
    final (status, body) = await get('/sources/mock_novel_declarative.json');
    expect(status, 200);
    final json = jsonDecode(body) as Map<String, dynamic>;
    expect(json['baseUrl'], 'http://127.0.0.1:${server.port}');
    expect(body, isNot(contains(MockServer.fixtureOrigin)));
  });

  test('列表页列出所有虚构源', () async {
    final (status, body) = await get('/sources/');
    expect(status, 200);
    expect(body, contains('/sources/mock_novel_declarative.json'));
    expect(body, contains('/sources/mock_comic_declarative.json'));
  });

  test('拒绝非法文件名（路径穿越），不存在的文件返回 404', () async {
    expect((await get('/sources/..%2F..%2Fpubspec.yaml')).$1, 400);
    expect((await get('/sources/nope.json')).$1, 404);
  });

  group('手动调试模式（rewriteFictionalHosts）', () {
    test('页面与 JSON 中的虚构图片主机换成请求地址；默认关闭', () async {
      final debug = await MockServer.start(rewriteFictionalHosts: true);
      addTearDown(debug.close);
      Future<String> body(MockServer s, String path) async {
        final req = await client.getUrl(s.origin.resolve(path));
        return utf8.decoder.bind(await req.close()).join();
      }

      final origin = 'http://127.0.0.1:${debug.port}';
      final chapter = await body(debug, '/comic/book/1/chapter/1');
      expect(chapter, contains('$origin/pages/'));
      expect(chapter, isNot(contains(MockServer.fictionalImageOrigin)));
      final api = await body(debug, '/api/search?q=x&page=1');
      expect(api, contains('$origin/covers/'));

      // 默认（单元测试）不改写。
      expect(
        await body(server, '/comic/book/1/chapter/1'),
        contains(MockServer.fictionalImageOrigin),
      );
    });
  });
}
