// 命令行启动 mock 服务器，供手动调试规则：
//
//   dart run tool/mock_server/main.dart [--port 8080] [--host 0.0.0.0] [--fixtures test/fixtures/mock_site]
//
// 调试时把源的 baseUrl 设为 http://127.0.0.1:<port>。
// 真机调试：加 `--host 0.0.0.0` 监听局域网，手机浏览器打开 http://<电脑局域网 IP>:<port>/sources/
// 复制虚构源 JSON（地址已换成局域网 IP）粘贴到应用中导入。
import 'dart:io';

import 'mock_server.dart';

Future<void> main(List<String> args) async {
  String? arg(String name) {
    final i = args.indexOf(name);
    return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
  }

  if (args.contains('-h') || args.contains('--help')) {
    stdout.writeln(
      'usage: dart run tool/mock_server/main.dart '
      '[--port 8080] [--host 127.0.0.1|0.0.0.0] [--fixtures test/fixtures/mock_site]',
    );
    return;
  }

  final host = arg('--host');
  final server = await MockServer.start(
    port: int.tryParse(arg('--port') ?? '') ?? 8080,
    address: host == null ? null : InternetAddress(host),
    fixturesDir: arg('--fixtures'),
  );
  stdout.writeln('mock server listening on ${server.origin}');
  if (host != null && host != '127.0.0.1') {
    // 列出局域网地址，方便手机访问；Windows 防火墙首次可能会询问是否允许。
    for (final iface in await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    )) {
      for (final a in iface.addresses) {
        if (a.isLoopback) continue;
        stdout.writeln(
          '  ${iface.name}: http://${a.address}:${server.port}/sources/',
        );
      }
    }
  }
  stdout.writeln(
    'routes: see tool/mock_server/mock_server.dart; Ctrl+C to stop',
  );

  final requests = server.requests;
  var printed = 0;
  // 简单的访问日志。
  Stream.periodic(const Duration(milliseconds: 200)).listen((_) {
    while (printed < requests.length) {
      stdout.writeln('  ${requests[printed++]}');
    }
  });
  await ProcessSignal.sigint.watch().first;
  await server.close();
  exit(0);
}
