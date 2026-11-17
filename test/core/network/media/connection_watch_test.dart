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
      socket.watch(
        req.connectionInfo!.remoteAddress,
        req.connectionInfo!.remotePort,
        closed.complete,
      );
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
        req.connectionInfo!.remoteAddress,
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

  test('按（对方地址, 对方端口）区分连接', () async {
    final watched = Completer<void>();
    final release = Completer<void>();
    var otherAddress = false;
    handler = (req) async {
      final info = req.connectionInfo!;
      // 同一端口、不同的回环地址：不是这个连接，立即通知。
      socket.watch(
        InternetAddress('127.0.0.2'),
        info.remotePort,
        () => otherAddress = true,
      );
      socket.watch(info.remoteAddress, info.remotePort, watched.complete);
      await release.future;
      try {
        await req.response.close();
      } catch (_) {}
    };
    final raw = await Socket.connect(InternetAddress.loopbackIPv4, server.port);
    raw.write('GET /a HTTP/1.1\r\nhost: example.com\r\n\r\n');
    raw.listen((_) {}, onError: (Object _) {});
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(otherAddress, isTrue);
    expect(watched.isCompleted, isFalse);
    raw.destroy();
    await watched.future.timeout(const Duration(seconds: 2));
    release.complete();
  });

  test('没有对应连接时立即通知', () {
    var notified = false;
    socket.watch(InternetAddress.loopbackIPv4, 1, () => notified = true);
    expect(notified, isTrue);
  });

  test('订阅方暂停时最多预读 64 KB（TCP 背压），交付之后继续读取', () async {
    // 不经 HttpServer：直接取得被监视的连接，订阅后立即暂停（相当于 dart:io 处理请求期间）。
    final direct = await WatchedServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(direct.close);
    final accepted = Completer<Socket>();
    direct.listen(accepted.complete);
    final raw = await Socket.connect(InternetAddress.loopbackIPv4, direct.port);
    final conn = await accepted.future;
    var received = 0;
    final sub = conn.listen((d) => received += d.length)..pause();
    var notified = false;
    direct.watch(raw.address, raw.port, () => notified = true);

    // 对方写 1 MB 后关闭：读取被背压挡住，读不到 EOF（也不会把 1 MB 都读进内存）。
    raw.add(List<int>.filled(1024 * 1024, 0x41));
    unawaited(raw.close().catchError((Object _) => raw));
    // 没有上限时，1 s 内会读完 1 MB 并读到 EOF。
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(notified, isFalse);
    expect(received, 0);

    // 恢复交付：全部读完，随后察觉关闭。
    sub.resume();
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!notified && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(notified, isTrue);
    expect(received, 1024 * 1024);
    await sub.cancel();
  });
}
