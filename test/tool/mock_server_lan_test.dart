import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/mock_server/lan.dart';
import '../../tool/mock_server/mock_server.dart';

void main() {
  test('代理虚拟网卡网段 198.18.0.0/15 被识别', () {
    expect(isVirtualProxyAddress(InternetAddress('198.18.0.1')), isTrue);
    expect(isVirtualProxyAddress(InternetAddress('198.19.255.254')), isTrue);
    expect(isVirtualProxyAddress(InternetAddress('198.20.0.1')), isFalse);
    expect(isVirtualProxyAddress(InternetAddress('192.168.1.100')), isFalse);
    expect(isVirtualProxyAddress(InternetAddress('::1')), isFalse);
  });

  test('只监听本机回环时，没有可供手机访问的局域网地址', () async {
    final server = await MockServer.start();
    addTearDown(server.close);
    expect(await reachableLanUrls(server), isEmpty);
  });

  test('列出的地址都实际可访问', () async {
    final server = await MockServer.start(address: InternetAddress.anyIPv4);
    addTearDown(server.close);
    final urls = await reachableLanUrls(server);
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    for (final u in urls) {
      final res = await (await client.getUrl(u.url)).close();
      await res.drain<void>();
      expect(res.statusCode, 200, reason: '${u.url}');
      expect(isVirtualProxyAddress(InternetAddress(u.url.host)), isFalse);
    }
  });
}
