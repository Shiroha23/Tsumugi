import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/sources/repository/providers.dart';

import '../../../tool/mock_server/mock_server.dart';

Matcher _throwsKind(RepositoryErrorKind kind) =>
    throwsA(isA<RepositoryException>().having((e) => e.kind, 'kind', kind));

void main() {
  late MockServer server;
  late RepositoryHttpClient client;

  setUpAll(() async => server = await MockServer.start());
  tearDownAll(() => server.close());
  setUp(() {
    server.requests.clear();
    client = RepositoryHttpClient(
      timeout: const Duration(seconds: 2),
      allowLoopbackHttp: true,
    );
  });
  tearDown(() => client.close());

  Uri url(String pathAndQuery) =>
      Uri.parse('http://127.0.0.1:${server.port}$pathAndQuery');

  test('取回原始字节；固定 UA，不带 Cookie / Referer', () async {
    // 服务器种下 Cookie：仓库客户端没有 Cookie Jar，之后的请求不会带上。
    await client.get(url('/cookie/set?name=c&value=1'), maxBytes: 1024);
    final res = await client.get(url('/echo'), maxBytes: 1 << 20);
    final echo = jsonDecode(utf8.decode(res.bytes)) as Map<String, dynamic>;
    final headers = (echo['headers'] as Map).cast<String, Object?>();
    expect(headers['user-agent'], RepositoryHttpClient.userAgent);
    expect(headers.containsKey('cookie'), isFalse);
    expect(headers.containsKey('referer'), isFalse);
    expect(res.url, url('/echo'));
  });

  test('请求前拒绝非 https（回环例外）', () async {
    expect(
      () => client.get(
        Uri.parse('http://repo.example.com/index.json'),
        maxBytes: 1024,
      ),
      _throwsKind(RepositoryErrorKind.insecureUrl),
    );
    expect(server.requests, isEmpty);
  });

  test('重定向的每一跳都检查：跳到 http 被拒绝，不发出请求', () async {
    await expectLater(
      client.get(
        url('/redirect?to=${Uri.encodeComponent('http://repo.example.com/x')}'),
        maxBytes: 1024,
      ),
      _throwsKind(RepositoryErrorKind.insecureUrl),
    );
    expect(server.requests.map((r) => r.path), ['/redirect']);
  });

  test('默认配置（应用）拒绝回环 http：既不能直接请求，也不能被重定向过去', () async {
    final strict = RepositoryHttpClient();
    addTearDown(strict.close);
    await expectLater(
      strict.get(url('/echo'), maxBytes: 1024),
      _throwsKind(RepositoryErrorKind.insecureUrl),
    );
    expect(server.requests, isEmpty);
    // 重定向的检查与首跳是同一判断：开启例外的客户端在第一跳之后遇到非回环 http 同样拒绝（见上），
    // 关闭例外时回环 http 本身就被拒绝。
    expect(
      isAllowedRepositoryUri(Uri.parse('http://localhost:8080/admin')),
      isFalse,
    );
  });

  test('重定向最多 5 跳', () async {
    final ok = await client.get(url('/redirect/chain?n=5'), maxBytes: 1 << 20);
    expect(ok.url.path, '/echo');
    await expectLater(
      client.get(url('/redirect/chain?n=6'), maxBytes: 1 << 20),
      _throwsKind(RepositoryErrorKind.tooManyRedirects),
    );
  });

  test('超过大小上限：按 Content-Length 与实际读取都拒绝', () async {
    await expectLater(
      client.get(url('/large?bytes=2049'), maxBytes: 2048),
      _throwsKind(RepositoryErrorKind.tooLarge),
    );
    await expectLater(
      client.get(url('/chunked?bytes=4096&chunk=512&length=0'), maxBytes: 2048),
      _throwsKind(RepositoryErrorKind.tooLarge),
    );
    final ok = await client.get(url('/large?bytes=2048'), maxBytes: 2048);
    expect(ok.bytes, hasLength(2048));
  });

  test('超过上限后中止读取，服务端停止发送', () async {
    await expectLater(
      client.get(
        url('/chunked?bytes=1000000&chunk=1024&ms=5&length=0&key=cap'),
        maxBytes: 4096,
      ),
      _throwsKind(RepositoryErrorKind.tooLarge),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(server.chunkedSent['cap'], lessThan(1000000 ~/ 2));
  });

  test('响应头迟迟不到：总时限内失败', () async {
    final sw = Stopwatch()..start();
    await expectLater(
      client.get(url('/slow?ms=3000'), maxBytes: 1024),
      _throwsKind(RepositoryErrorKind.network),
    );
    expect(sw.elapsed, lessThan(const Duration(milliseconds: 2800)));
  });

  test('多跳重定向累计计时：每跳都快但总时长超限也失败', () async {
    final slowAfterRedirects = url(
      '/redirect?to=${Uri.encodeComponent('/redirect?to=${Uri.encodeComponent('/slow-body?ms=3000')}')}',
    );
    await expectLater(
      client.get(slowAfterRedirects, maxBytes: 1024),
      _throwsKind(RepositoryErrorKind.network),
    );
  });

  test('非 2xx → http 错误，带状态码', () async {
    await expectLater(
      client.get(url('/status/404'), maxBytes: 1024),
      throwsA(
        isA<RepositoryException>()
            .having((e) => e.kind, 'kind', RepositoryErrorKind.http)
            .having((e) => e.status, 'status', 404),
      ),
    );
  });

  test('整次获取超时（含读取响应体）', () async {
    await expectLater(
      client.get(url('/slow-body?ms=3000'), maxBytes: 1024),
      _throwsKind(RepositoryErrorKind.network),
    );
  });

  test('连接失败 → network', () async {
    final closed = await MockServer.start();
    final port = closed.port;
    await closed.close();
    await expectLater(
      client.get(Uri.parse('http://127.0.0.1:$port/'), maxBytes: 1024),
      _throwsKind(RepositoryErrorKind.network),
    );
  });
}
