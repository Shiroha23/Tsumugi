// 命令行启动 mock 服务器，供手动调试规则：
//
//   dart run tool/mock_server/main.dart [--port 8080] [--fixtures test/fixtures/mock_site]
//
// 调试时把源的 baseUrl 设为 http://127.0.0.1:<port>。
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
      '[--port 8080] [--fixtures test/fixtures/mock_site]',
    );
    return;
  }

  final server = await MockServer.start(
    port: int.tryParse(arg('--port') ?? '') ?? 8080,
    fixturesDir: arg('--fixtures'),
  );
  stdout.writeln('mock server listening on ${server.origin}');
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
