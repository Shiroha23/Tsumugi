import 'dart:convert';
import 'dart:io';

import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/network/dio_source_http_client.dart';
import 'package:tsumugi/core/network/network_exception.dart';
import 'package:tsumugi/core/network/source_http_client.dart';
import 'package:tsumugi/core/subtitle/subtitle_loader.dart';
import 'package:tsumugi/core/subtitle/subtitle_parser.dart';

import '../network/mock_support.dart';

/// 测试内的上游：按路径返回预设响应，并记录请求。
class _Upstream {
  _Upstream._(this._server);

  final HttpServer _server;
  final requests = <HttpRequest>[];
  final handlers = <String, Future<void> Function(HttpResponse res)>{};

  static Future<_Upstream> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final up = _Upstream._(server);
    server.listen((req) async {
      up.requests.add(req);
      final h = up.handlers[req.uri.path];
      if (h == null) {
        req.response.statusCode = 404;
        await req.response.close();
        return;
      }
      try {
        await h(req.response);
      } on Object {
        // 客户端中止时写入失败。
      }
    });
    return up;
  }

  int get port => _server.port;

  Future<void> close() => _server.close(force: true);
}

DioSourceHttpClient _client(
  _Upstream up, {
  List<String> allowedHosts = const [],
}) => DioSourceHttpClient(
  SourceNetworkConfig(
    sourceId: 'com.example.subs',
    baseUrl: Uri.parse('http://video.example.com'),
    allowedHosts: allowedHosts,
    defaultHeaders: const {'Referer': 'http://video.example.com/'},
    timeout: const Duration(seconds: 5),
    maxRetries: 0,
  ),
  adapter: IOHttpClientAdapter(
    createHttpClient: () =>
        HttpClient()
          ..connectionFactory = (uri, proxyHost, proxyPort) =>
              Socket.startConnect(InternetAddress.loopbackIPv4, up.port),
  ),
);

void main() {
  late _Upstream up;
  late DioSourceHttpClient client;

  setUp(() async {
    up = await _Upstream.start();
    client = _client(up);
  });
  tearDown(() async {
    client.close();
    await up.close();
  });

  Future<void> Function(HttpResponse) bytes(
    List<int> body, {
    String? type,
    bool chunked = false,
  }) => (res) async {
    if (type != null) res.headers.set(HttpHeaders.contentTypeHeader, type);
    if (!chunked) res.contentLength = body.length;
    res.add(body);
    await res.close();
  };

  test('经源的网络层取回（默认 headers）；相对地址基于 baseUrl', () async {
    up.handlers['/s/zh.srt'] = bytes(
      utf8.encode('1\n00:00:00,000 --> 00:00:01,000\n你好\n'),
      type: 'text/plain',
    );
    final doc = await fetchSubtitle(client, '/s/zh.srt', format: 'srt');
    expect(doc.cues.single.text, '你好');
    final req = up.requests.single;
    expect(req.headers.host, 'video.example.com');
    expect(req.headers.value('referer'), 'http://video.example.com/');
  });

  test('GBK，Content-Type 不带 charset', () async {
    up.handlers['/gbk.srt'] = bytes(
      File('test/fixtures/mock_site/video/subs/zh_gbk.srt').readAsBytesSync(),
      type: 'text/plain',
    );
    final doc = await fetchSubtitle(client, '/gbk.srt');
    expect(doc.cues.first.text, 'GBK 字幕：第一段');
  });

  test('声明的 charset', () async {
    up.handlers['/big5.srt'] = bytes([
      ...ascii.encode('00:00:00,000 --> 00:00:01,000\n'),
      0xA4, 0xA4, 0xA4, 0xE5, // “中文”（Big5）
    ]);
    final doc = await fetchSubtitle(client, '/big5.srt', charset: 'big5');
    expect(doc.cues.single.text, '中文');
  });

  test('Content-Length 超过上限：不读响应体', () async {
    up.handlers['/big.srt'] = bytes(List.filled(maxSubtitleBytes + 1, 0x41));
    await expectLater(
      fetchSubtitle(client, '/big.srt'),
      throwsA(
        isA<SubtitleFormatException>().having(
          (e) => e.message,
          'message',
          '字幕文件超过 4 MB',
        ),
      ),
    );
  });

  test('没有 Content-Length、读取中超过上限：拒绝，不再缓存', () async {
    up.handlers['/stream.srt'] = (res) async {
      try {
        for (var i = 0; i < 64; i++) {
          res.add(List.filled(1024, 0x41));
          await res.flush();
        }
        await res.close();
      } on Object {
        // 客户端中止
      }
    };
    await expectLater(
      fetchSubtitle(client, '/stream.srt', maxBytes: 4096),
      throwsA(
        isA<SubtitleFormatException>().having(
          (e) => e.message,
          'message',
          '字幕文件超过 4 KB',
        ),
      ),
    );
  });

  test('大文件在后台 isolate 中解析', () async {
    final b = StringBuffer();
    for (var i = 0; b.length <= isolateThreshold; i++) {
      b.write('${i + 1}\n00:00:00,000 --> 00:00:01,000\n${'字' * 40}\n\n');
    }
    up.handlers['/large.srt'] = bytes(utf8.encode(b.toString()), chunked: true);
    final doc = await fetchSubtitle(client, '/large.srt');
    expect(doc.cues, isNotEmpty);
  });

  test('非 2xx 抛 NetworkException(http)', () async {
    await expectLater(
      fetchSubtitle(client, '/missing.srt'),
      throwsA(
        isA<NetworkException>()
            .having((e) => e.kind, 'kind', NetworkErrorKind.http)
            .having((e) => e.status, 'status', 404),
      ),
    );
  });

  test('白名单外拒绝，不发请求', () async {
    await expectLater(
      fetchSubtitle(client, 'http://other.example.org/a.srt'),
      throwsA(
        isA<NetworkException>().having(
          (e) => e.kind,
          'kind',
          NetworkErrorKind.hostNotAllowed,
        ),
      ),
    );
    expect(up.requests, isEmpty);
  });

  test('HTML 错误页（200）按内容拒绝', () async {
    up.handlers['/bad.srt'] = bytes(
      File('test/fixtures/mock_site/video/subs/bad.srt').readAsBytesSync(),
      type: 'text/plain',
    );
    await expectLater(
      fetchSubtitle(client, '/bad.srt', format: 'srt'),
      throwsA(isA<SubtitleFormatException>()),
    );
  });

  test('不支持的 format 声明直接拒绝', () async {
    await expectLater(
      fetchSubtitle(client, '/x.ttml', format: 'ttml'),
      throwsA(isA<SubtitleFormatException>()),
    );
    expect(up.requests, isEmpty);
  });

  // 审查意见 2：总时限与取消。
  Future<void> Function(HttpResponse) slow() => (res) async {
    try {
      res.write('1\n00:00:00,000 --> 00:00:01,000\n');
      await res.flush();
      for (var i = 0; i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        res.write('x');
        await res.flush();
      }
      await res.close();
    } on Object {
      // 客户端中止
    }
  };

  test('慢速上游：超过总时限抛 timeout', () async {
    up.handlers['/slow.srt'] = slow();
    final sw = Stopwatch()..start();
    await expectLater(
      fetchSubtitle(
        client,
        '/slow.srt',
        totalTimeout: const Duration(milliseconds: 500),
      ),
      throwsA(
        isA<NetworkException>().having(
          (e) => e.kind,
          'kind',
          NetworkErrorKind.timeout,
        ),
      ),
    );
    expect(sw.elapsed, lessThan(const Duration(seconds: 3)));
  });

  test('读取期间取消抛 cancelled', () async {
    up.handlers['/slow.srt'] = slow();
    final cancel = NetCancellation();
    final future = fetchSubtitle(client, '/slow.srt', cancellation: cancel);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    cancel.cancel();
    await expectLater(
      future,
      throwsA(
        isA<NetworkException>().having(
          (e) => e.kind,
          'kind',
          NetworkErrorKind.cancelled,
        ),
      ),
    );
  });

  test('等待响应头期间取消抛 cancelled', () async {
    up.handlers['/hang.srt'] = (res) async {
      await Future<void>.delayed(const Duration(seconds: 3));
      await res.close();
    };
    final cancel = NetCancellation();
    final future = fetchSubtitle(client, '/hang.srt', cancellation: cancel);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    cancel.cancel();
    await expectLater(
      future,
      throwsA(
        isA<NetworkException>().having(
          (e) => e.kind,
          'kind',
          NetworkErrorKind.cancelled,
        ),
      ),
    );
  });

  test('重定向到白名单外拒绝', () async {
    up.handlers['/redirect.srt'] = (res) async {
      res.statusCode = 302;
      res.headers.set('location', 'http://other.example.org/a.srt');
      await res.close();
    };
    await expectLater(
      fetchSubtitle(client, '/redirect.srt'),
      throwsA(
        isA<NetworkException>().having(
          (e) => e.kind,
          'kind',
          NetworkErrorKind.hostNotAllowed,
        ),
      ),
    );
    expect(up.requests.map((r) => r.uri.path), ['/redirect.srt']);
  });

  test('空的 format 按未给出处理', () async {
    up.handlers['/a.srt'] = bytes(
      utf8.encode('1\n00:00:00,000 --> 00:00:01,000\nok\n'),
    );
    final doc = await fetchSubtitle(client, '/a.srt', format: '  ');
    expect(doc.cues.single.text, 'ok');
  });

  group('mock 服务器', () {
    late MockServer server;
    late DioSourceHttpClient mock;

    setUp(() async {
      server = await MockServer.start();
      mock = mockClient(
        server,
        sourceId: 'com.example.video',
        baseUrl: 'http://video.example.com',
        headers: {'Referer': 'http://video.example.com/video/'},
      );
    });
    tearDown(() async {
      mock.close();
      await server.close();
    });

    test('五条外挂字幕：四条可用，bad.srt 被拒绝', () async {
      for (final (name, format, first) in [
        ('zh.srt', 'srt', '第一段：彩条开始'),
        ('zh_gbk.srt', null, 'GBK 字幕：第一段'),
        ('en.vtt', 'vtt', 'Color bars & a tone'),
        ('ja.ass', 'ass', '一つ目, comma kept\nnext line'),
      ]) {
        final doc = await fetchSubtitle(
          mock,
          '/video/protected/subs/$name',
          format: format,
        );
        expect(doc.cues.first.text, first, reason: name);
        expect(doc.cues.length, 3, reason: name);
      }
      await expectLater(
        fetchSubtitle(mock, '/video/media/subs/bad.srt', format: 'srt'),
        throwsA(isA<SubtitleFormatException>()),
      );
    });
  });
}
