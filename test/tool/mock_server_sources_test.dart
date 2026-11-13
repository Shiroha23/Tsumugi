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
}
