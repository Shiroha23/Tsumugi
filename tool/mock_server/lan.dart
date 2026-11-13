import 'dart:async';
import 'dart:io';

import 'mock_server.dart';

/// 本机可供手机访问的 `/sources/` 地址。
///
/// 系统网卡列表里可能有已断开网卡残留的地址，也可能有代理软件的虚拟网卡，
/// 所以对每个候选地址实际请求一次本服务器的 `/sources/`，只保留能访问通的；
/// 并排除代理虚拟网卡常用的保留网段（[isVirtualProxyAddress]）。
Future<List<({String interface, Uri url})>> reachableLanUrls(
  MockServer server, {
  Duration timeout = const Duration(seconds: 1),
}) async {
  final candidates = <({String interface, InternetAddress address})>[
    for (final iface in await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    ))
      for (final a in iface.addresses)
        if (!a.isLoopback && !isVirtualProxyAddress(a))
          (interface: iface.name, address: a),
  ];
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final results = await Future.wait([
      for (final c in candidates)
        _probe(client, server, c.address, timeout).then(
          (ok) => ok
              ? (
                  interface: c.interface,
                  url: Uri.parse(
                    'http://${c.address.address}:${server.port}/sources/',
                  ),
                )
              : null,
        ),
    ]);
    return results.nonNulls.toList();
  } finally {
    client.close(force: true);
  }
}

Future<bool> _probe(
  HttpClient client,
  MockServer server,
  InternetAddress address,
  Duration timeout,
) async {
  try {
    final req = await client
        .getUrl(Uri.parse('http://${address.address}:${server.port}/sources/'))
        .timeout(timeout);
    final res = await req.close().timeout(timeout);
    await res.drain<void>();
    return res.statusCode == HttpStatus.ok;
  } on Object {
    return false;
  }
}

/// `198.18.0.0/15`：RFC 2544 基准测试保留网段，Clash 等代理软件的 TUN 虚拟网卡常用，手机无法访问。
bool isVirtualProxyAddress(InternetAddress a) {
  if (a.type != InternetAddressType.IPv4) return false;
  final b = a.rawAddress;
  return b[0] == 198 && (b[1] == 18 || b[1] == 19);
}
