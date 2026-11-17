import 'dart:async';
import 'dart:io';

import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/network/dio_source_http_client.dart';
import 'package:tsumugi/core/network/source_http_client.dart';

/// 慢速、持续写入的上游：接管 socket 后自己写响应，以便看到连接是否被对方关闭（#52）。
///
/// 不能用 dart:io 的 `HttpResponse` 判断：连接被对方关闭后，它的 `add` / `flush` 仍然“成功”，
/// `done` 也不报错（服务端的连接数已经是 0），看起来就像上游还在持续写入。
///
/// 客户端只是“停止读取”时，TCP 缓冲区写满后上游的写入会阻塞，但连接仍在；
/// 只有客户端真正关闭连接，上游才会读到 EOF（[closed] 完成）或写入失败。
class SlowUpstream {
  SlowUpstream._(this._server) {
    _server.listen(_handle);
  }

  static Future<SlowUpstream> start() async =>
      SlowUpstream._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;
  int get port => _server.port;

  /// 每个连接被对方关闭（读到 EOF、写入失败）时完成。
  final _closed = <Completer<void>>[];
  final _accepted = StreamController<Completer<void>>.broadcast();
  Stream<Completer<void>> get accepted => _accepted.stream;
  int written = 0;

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest req) async {
    final socket = await req.response.detachSocket(writeHeaders: false);
    final closed = Completer<void>();
    _closed.add(closed);
    _accepted.add(closed);
    void markClosed() {
      if (!closed.isCompleted) closed.complete();
    }

    socket.listen(
      (_) {},
      onDone: markClosed,
      onError: (Object _) => markClosed(),
    );
    socket.done.then((_) => markClosed(), onError: (Object _) => markClosed());
    socket.write(
      'HTTP/1.1 200 OK\r\n'
      'content-type: application/octet-stream\r\n'
      'content-length: ${64 * 1024 * 1024}\r\n'
      '\r\n',
    );
    final chunk = List<int>.filled(64 * 1024, 0x47);
    // 持续写入（最多 64 MB），每块之间稍作停顿，直到连接被关闭。
    try {
      while (!closed.isCompleted && written < 64 * 1024 * 1024) {
        socket.add(chunk);
        await socket.flush();
        written += chunk.length;
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
    } catch (_) {
      markClosed();
    }
    socket.destroy();
  }
}

void main() {
  late SlowUpstream upstream;
  late DioSourceHttpClient client;

  setUp(() async {
    upstream = await SlowUpstream.start();
    client = DioSourceHttpClient(
      SourceNetworkConfig(
        sourceId: 'com.example.video',
        baseUrl: Uri.parse('http://video.example.com'),
        timeout: const Duration(seconds: 5),
      ),
      adapter: IOHttpClientAdapter(
        createHttpClient: () => HttpClient()
          ..connectionFactory = (uri, proxyHost, proxyPort) =>
              Socket.startConnect(InternetAddress.loopbackIPv4, upstream.port),
      ),
    );
  });
  tearDown(() async {
    client.close();
    await upstream.close();
  });

  Future<Completer<void>> openAndRead(
    Future<void> Function(NetStreamResponse res, StreamSubscription sub) stop,
  ) async {
    final conn = upstream.accepted.first;
    final res = await client.openStream(const NetRequest('/stream.mp4'));
    final closed = await conn;
    var received = 0;
    final first = Completer<void>();
    late StreamSubscription<List<int>> sub;
    sub = res.body.listen((c) {
      received += c.length;
      if (received > 256 * 1024 && !first.isCompleted) first.complete();
    }, onError: (Object _) {});
    await first.future;
    await stop(res, sub);
    return closed;
  }

  test('对照：只暂停读取时连接保持（检测能区分两种情况）', () async {
    final closed = await openAndRead((_, sub) async => sub.pause());
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(closed.isCompleted, isFalse);
  });

  test('取消订阅响应体后上游连接被关闭', () async {
    final closed = await openAndRead((_, sub) => sub.cancel());
    await closed.future.timeout(const Duration(seconds: 3));
  });

  test('NetStreamResponse.cancel() 后上游连接被关闭', () async {
    final closed = await openAndRead((res, _) async => res.cancel());
    await closed.future.timeout(const Duration(seconds: 3));
  });

  test('NetCancellation 取消后上游连接被关闭', () async {
    final c = NetCancellation();
    final conn = upstream.accepted.first;
    final res = await client.openStream(
      NetRequest('/stream.mp4', cancellation: c),
    );
    final closed = await conn;
    res.body.listen((_) {}, onError: (Object _) {});
    await Future<void>.delayed(const Duration(milliseconds: 100));
    c.cancel();
    await closed.future.timeout(const Duration(seconds: 3));
  });

  test('client.close() 后上游连接被关闭', () async {
    final closed = await openAndRead((_, _) async => client.close());
    await closed.future.timeout(const Duration(seconds: 3));
  });
}
