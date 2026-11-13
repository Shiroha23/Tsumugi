import 'package:cookie_jar/cookie_jar.dart';

import 'host_policy.dart';
import 'network_exception.dart';

/// 一个源的会话状态：Cookie Jar、从 WebView 同步来的 User-Agent、最近一次检测到挑战的地址
/// （docs/architecture.md §5.3）。
///
/// 同一个源的所有 [SourceHttpClient]（源实例、图片加载）共用同一个会话，
/// 因此登录 / 验证得到的 Cookie 对它们都有效。不同源的会话互不相通。
class SourceSession {
  SourceSession({CookieJar? cookieJar})
    : cookieJar = SecureCookieJar(cookieJar ?? CookieJar());

  /// 本源的 Cookie Jar（已包装为 [SecureCookieJar]）。
  final CookieJar cookieJar;

  /// WebView 验证时使用的 User-Agent。清单未设置 `User-Agent` 时，本源的请求以它作为默认 UA
  /// （优先级：请求 headers > 清单 headers > 此值）。
  String? userAgent;

  /// 网络层最近一次检测到人机验证页面的地址（已在白名单内），供「打开验证页」使用。
  Uri? lastChallengeUrl;

  /// 把在 [url] 上从 WebView 读到的 [cookies] 写入本会话。
  ///
  /// - [url] 必须通过 [policy]，否则抛出 [NetworkErrorKind.hostNotAllowed]。
  /// - 每个 Cookie 以**主机限定**的形式保存在 `url.host` 上（不保留 Domain，避免扩散到
  ///   白名单之外的主机）；带 Domain 的 Cookie 只有在 `url.host` 属于该 Domain 时才接受。
  /// - Path / 过期时间 / Secure / HttpOnly 原样保留；已过期或名称 / 值不合法的 Cookie 被跳过。
  ///
  /// 返回实际写入的 Cookie 数。
  Future<int> importCookies(
    Uri url,
    Iterable<WebCookie> cookies,
    HostPolicy policy, {
    DateTime? now,
  }) async {
    if (!policy.isAllowed(url)) {
      throw NetworkException(
        NetworkErrorKind.hostNotAllowed,
        message: 'host not allowed: ${url.host}',
        uri: url,
      );
    }
    final host = url.host.toLowerCase();
    final at = now ?? DateTime.now();
    final accepted = <Cookie>[];
    for (final c in cookies) {
      if (c.domain case final domain? when !_domainMatches(host, domain)) {
        continue;
      }
      if (c.expires case final e? when !e.isAfter(at)) continue;
      final Cookie cookie;
      try {
        cookie = Cookie(c.name, c.value)
          ..path = (c.path == null || c.path!.isEmpty) ? '/' : c.path
          ..expires = c.expires
          ..secure = c.secure
          ..httpOnly = c.httpOnly;
      } on FormatException {
        continue;
      }
      accepted.add(cookie);
    }
    if (accepted.isEmpty) return 0;
    // 只取 scheme / host / port，避免 cookie_jar 按请求路径推断默认 Path。
    await cookieJar.saveFromResponse(
      Uri(scheme: url.scheme, host: url.host, port: url.port, path: '/'),
      accepted,
    );
    return accepted.length;
  }

  static bool _domainMatches(String host, String domain) {
    var d = domain.toLowerCase();
    if (d.startsWith('.')) d = d.substring(1);
    if (d.isEmpty) return false;
    return host == d || host.endsWith('.$d');
  }
}

/// 从 WebView 读到的一个 Cookie（与具体 WebView 插件无关）。
class WebCookie {
  const WebCookie({
    required this.name,
    required this.value,
    this.domain,
    this.path,
    this.expires,
    this.secure = false,
    this.httpOnly = false,
  });

  final String name;
  final String value;

  /// 为 null 表示平台没有提供（如 Android 只返回 name=value）。
  final String? domain;
  final String? path;

  /// 为 null 表示会话 Cookie。
  final DateTime? expires;
  final bool secure;
  final bool httpOnly;

  @override
  String toString() => 'WebCookie($name, domain: $domain, path: $path)';
}

/// 修正 `cookie_jar` 默认实现的一个问题：它对未过期的 Secure Cookie 不检查 scheme，
/// 会把它们发往 http 地址。这里在读取时去掉发往非 https 地址的 Secure Cookie
/// （`CookieManager` 对每一跳重定向都会调用 [loadForRequest]）。
class SecureCookieJar implements CookieJar {
  SecureCookieJar(this.inner);

  final CookieJar inner;

  @override
  bool get ignoreExpires => inner.ignoreExpires;

  @override
  Future<List<Cookie>> loadForRequest(Uri uri) async {
    final cookies = await inner.loadForRequest(uri);
    if (uri.scheme == 'https') return cookies;
    return [
      for (final c in cookies)
        if (!c.secure) c,
    ];
  }

  @override
  Future<void> saveFromResponse(Uri uri, List<Cookie> cookies) =>
      inner.saveFromResponse(uri, cookies);

  @override
  Future<void> delete(Uri uri, [bool withDomainSharedCookie = false]) =>
      inner.delete(uri, withDomainSharedCookie);

  @override
  Future<void> deleteAll() => inner.deleteAll();
}
