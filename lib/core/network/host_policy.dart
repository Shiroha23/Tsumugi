import 'host_name.dart';

/// 源的网络白名单（docs/source-spec.md §5）。
///
/// 允许的主机 = `baseUrl` 的主机 + `allowedHosts`。
/// `allowedHosts` 支持 `*.example.com` 通配，匹配任意层级子域名，但不匹配 `example.com` 本身。
///
/// 白名单与请求主机都经过 [normalizeHost]：忽略大小写与结尾的 `.`，
/// 国际化域名的 Unicode 写法与 Punycode 写法视为同一主机。端口与 userinfo 不参与匹配。
/// 无法规范化的白名单条目被忽略，无法规范化的请求主机一律拒绝。
class HostPolicy {
  HostPolicy({required Uri baseUrl, Iterable<String> allowedHosts = const []})
    : _exact = {
        ?normalizeHost(baseUrl.host),
        for (final h in allowedHosts)
          if (!h.startsWith('*.')) ?normalizeHost(h),
      },
      _suffixes = [
        for (final h in allowedHosts)
          if (h.startsWith('*.'))
            if (normalizeHost(h.substring(2)) case final s?) '.$s',
      ];

  final Set<String> _exact;

  /// 形如 `.example.com`，带前导点以免匹配到 `xexample.com`。
  final List<String> _suffixes;

  bool isAllowed(Uri uri) {
    if (uri.scheme != 'http' && uri.scheme != 'https') return false;
    final host = normalizeHost(uri.host);
    if (host == null) return false;
    if (_exact.contains(host)) return true;
    return _suffixes.any(host.endsWith);
  }
}
