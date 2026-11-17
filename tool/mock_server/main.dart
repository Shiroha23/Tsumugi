// 命令行启动 mock 服务器，供手动调试规则：
//
//   dart run tool/mock_server/main.dart [--port 8080] [--host 0.0.0.0] [--fixtures test/fixtures/mock_site] [--test-control]
//
// 调试时把源的 baseUrl 设为 http://127.0.0.1:<port>。
// 真机调试：加 `--host 0.0.0.0` 监听局域网，手机浏览器打开 http://<电脑局域网 IP>:<port>/sources/
// 复制虚构源 JSON（地址已换成局域网 IP）粘贴到应用中导入。
//
// 在 Android 设备上跑集成测试：加 `--test-control`（开启 /__test/* 控制接口、不改写虚构主机名），
// 见 integration_test/video_playback_test.dart 顶部注释。
import 'dart:io';

import 'lan.dart';
import 'mock_server.dart';

Future<void> main(List<String> args) async {
  String? arg(String name) {
    final i = args.indexOf(name);
    return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
  }

  if (args.contains('-h') || args.contains('--help')) {
    stdout.writeln(
      'usage: dart run tool/mock_server/main.dart '
      '[--port 8080] [--host 127.0.0.1|0.0.0.0] [--fixtures test/fixtures/mock_site] '
      '[--test-control]',
    );
    return;
  }

  final host = arg('--host');
  final testControl = args.contains('--test-control');
  final server = await MockServer.start(
    port: int.tryParse(arg('--port') ?? '') ?? 8080,
    address: host == null ? null : InternetAddress(host),
    fixturesDir: arg('--fixtures'),
    // 手动调试：图片地址也指向本服务器（见 MockServer.rewriteFictionalHosts）。
    // 集成测试经自定义连接访问虚构主机名，并断言虚构主机名本身，不改写。
    rewriteFictionalHosts: !testControl,
    testControl: testControl,
  );
  stdout.writeln('mock server listening on ${server.origin}');
  if (host != null && host != '127.0.0.1') {
    // 只列出实际访问得通的局域网地址（排除已断开网卡的残留地址与代理虚拟网卡）。
    final urls = await reachableLanUrls(server);
    if (urls.isEmpty) {
      stdout.writeln('  （没有找到可访问的局域网地址：检查网络连接与 Windows 防火墙）');
    }
    for (final u in urls) {
      stdout.writeln('  ${u.interface}: ${u.url}');
    }
  }
  stdout.writeln(
    'routes: see tool/mock_server/mock_server.dart; Ctrl+C to stop',
  );

  // 简单的访问日志（跳过启动时探测局域网地址产生的请求）。按对象记住已输出的最后一条，
  // 请求记录被 /__test/reset 清空后也不会漏行。
  final requests = server.requests;
  RecordedRequest? last = requests.isEmpty ? null : requests.last;
  Stream.periodic(const Duration(milliseconds: 200)).listen((_) {
    final from = last == null ? 0 : requests.lastIndexOf(last!) + 1;
    for (var i = from; i < requests.length; i++) {
      stdout.writeln('  ${requests[i]}');
    }
    if (requests.isNotEmpty) last = requests.last;
  });
  await ProcessSignal.sigint.watch().first;
  await server.close();
  exit(0);
}
