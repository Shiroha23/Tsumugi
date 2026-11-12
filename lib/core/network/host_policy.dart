/// 源的网络白名单（docs/source-spec.md §5）。
///
/// 允许的主机 = `baseUrl` 的主机 + `allowedHosts`。
/// `allowedHosts` 支持 `*.example.com` 通配，匹配任意层级子域名，但不匹配 `example.com` 本身。
class HostPolicy {
  HostPolicy({required Uri baseUrl, Iterable<String> allowedHosts = const []})
    : _exact = {
        baseUrl.host.toLowerCase(),
        for (final h in allowedHosts)
          if (!h.startsWith('*.')) h.toLowerCase(),
      },
      _suffixes = [
        for (final h in allowedHosts)
          if (h.startsWith('*.'))
            h.substring(1).toLowerCase(), // ".example.com"
      ];

  final Set<String> _exact;
  final List<String> _suffixes;

  bool isAllowed(Uri uri) {
    if (uri.scheme != 'http' && uri.scheme != 'https') return false;
    final host = uri.host.toLowerCase();
    if (host.isEmpty) return false;
    if (_exact.contains(host)) return true;
    return _suffixes.any(host.endsWith);
  }
}
