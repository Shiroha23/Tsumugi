// 集成测试的 mock 服务器：桌面上在测试进程内启动（读取工作目录下的 test/fixtures/）；
// 在 Android 等设备上读不到电脑的文件，改为连接电脑上以 `--test-control` 启动的 mock 服务器
// （`--dart-define=TSUMUGI_MOCK_SERVER=<电脑局域网 IP>:<端口>`），见 video_playback_test.dart 顶部注释。
//
// 两种方式下，所有 HTTP 连接都经自定义连接接到 mock 服务器，虚构主机名（video.example.com 等）照常可用，
// 白名单仍按虚构主机名检查。
import 'dart:convert';
import 'dart:io';

import 'package:dio/io.dart';

import '../test/core/network/mock_support.dart';

/// 设备上运行时，电脑上 mock 服务器的 `<主机>:<端口>`；为空时在本进程内启动。
const remoteMockServer = String.fromEnvironment('TSUMUGI_MOCK_SERVER');

abstract class TestMock {
  static Future<TestMock> start() async {
    if (remoteMockServer.isEmpty) return _LocalMock(await MockServer.start());
    final (host, port) = switch (remoteMockServer.split(':')) {
      [final h, final p] when int.tryParse(p) != null => (h, int.parse(p)),
      _ => throw ArgumentError('TSUMUGI_MOCK_SERVER 应为 <主机>:<端口>'),
    };
    final remote = _RemoteMock(InternetAddress(host), port);
    await remote._post('/__test/reset');
    return remote;
  }

  /// 把任意主机名的连接都接到 mock 服务器的 HTTP 适配器（每个客户端各用一个）。
  IOHttpClientAdapter adapter();

  /// 本测试开始以来服务器收到的请求。
  Future<List<RecordedRequest>> requests();

  /// `test/fixtures/` 下的文件内容（如 `sources/mock_video_script.json`）。
  Future<String> fixture(String path);

  Future<void> close();
}

class _LocalMock implements TestMock {
  _LocalMock(this.server);

  final MockServer server;

  @override
  IOHttpClientAdapter adapter() => mockAdapter(server);

  @override
  Future<List<RecordedRequest>> requests() async => List.of(server.requests);

  @override
  Future<String> fixture(String path) =>
      File('test/fixtures/$path').readAsString();

  @override
  Future<void> close() => server.close();
}

class _RemoteMock implements TestMock {
  _RemoteMock(this.address, this.port);

  final InternetAddress address;
  final int port;
  final _http = HttpClient();

  @override
  IOHttpClientAdapter adapter() => IOHttpClientAdapter(
    createHttpClient: () =>
        HttpClient()
          ..connectionFactory = (uri, proxyHost, proxyPort) =>
              Socket.startConnect(address, port),
  );

  Uri _uri(String path, [Map<String, String>? query]) => Uri(
    scheme: 'http',
    host: address.address,
    port: port,
    path: path,
    queryParameters: query,
  );

  Future<String> _get(String path, [Map<String, String>? query]) async {
    final req = await _http.getUrl(_uri(path, query));
    final res = await req.close();
    final body = await utf8.decodeStream(res);
    if (res.statusCode != 200) {
      throw HttpException('mock ${res.statusCode}: $path', uri: _uri(path));
    }
    return body;
  }

  Future<void> _post(String path) async {
    final res = await (await _http.postUrl(_uri(path))).close();
    await res.drain<void>();
    if (res.statusCode != 200) {
      throw HttpException(
        'mock ${res.statusCode}: $path（服务器是否以 --test-control 启动？）',
        uri: _uri(path),
      );
    }
  }

  @override
  Future<List<RecordedRequest>> requests() async => [
    for (final r in jsonDecode(await _get('/__test/requests')) as List)
      RecordedRequest(
        method: r['method'] as String,
        host: r['host'] as String,
        path: r['path'] as String,
        query: (r['query'] as Map).cast<String, String>(),
        headers: (r['headers'] as Map).cast<String, String>(),
        body: r['body'] as String,
      ),
  ];

  @override
  Future<String> fixture(String path) =>
      _get('/__test/fixture', {'path': path});

  @override
  Future<void> close() async => _http.close(force: true);
}
