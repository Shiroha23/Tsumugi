import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/network/media/connection_watch.dart';

void main() {
  late WatchedServerSocket socket;
  late HttpServer server;
  late Future<void> Function(HttpRequest req) handler;

  setUp(() async {
    socket = await WatchedServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server = HttpServer.listenOn(socket)..listen((req) => handler(req));
  });
  tearDown(() async {
    await server.close(force: true);
    await socket.close();
  });

  test('处理请求期间（尚未写入）对方断开：立即通知', () async {
    final closed = Completer<void>();
    final release = Completer<void>();
    handler = (req) async {
      socket.watch(req.connectionInfo!.remotePort, closed.complete);
      await release.future; // 模拟排队 / 等上游
      try {
        await req.response.close();
      } catch (_) {}
    };
    final raw = await Socket.connect(InternetAddress.loopbackIPv4, server.port);
    raw.write('GET /a HTTP/1.1\r\nhost: example.com\r\n\r\n');
    raw.listen((_) {}, onError: (Object _) {});
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(closed.isCompleted, isFalse);
    raw.destroy();
    await closed.future.timeout(const Duration(seconds: 2));
    release.complete();
  });

  test('keep-alive 连接上的请求照常处理；注销后连接关闭也不再通知', () async {
    var notified = 0;
    handler = (req) async {
      final unwatch = socket.watch(
        req.connectionInfo!.remotePort,
        () => notified++,
      );
      req.response.write('ok ${req.uri.path}');
      await req.response.close();
      unwatch();
    };
    final client = HttpClient();
    for (final path in ['/1', '/2', '/3']) {
      final res = await (await client.get(
        '127.0.0.1',
        server.port,
        path,
      )).close();
      expect(await utf8.decodeStream(res), 'ok $path');
    }
    client.close(force: true);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(notified, 0);
  });

  test('没有对应连接时立即通知', () {
    var notified = false;
    socket.watch(1, () => notified = true);
    expect(notified, isTrue);
  });
}
