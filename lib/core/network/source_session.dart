import 'dart:async';

import 'package:cookie_jar/cookie_jar.dart';

import 'host_policy.dart';
import 'network_exception.dart';
import 'session_persistence.dart';

/// 一个源的会话状态：Cookie Jar、从 WebView 同步来的 User-Agent、最近一次检测到挑战的地址
/// （docs/architecture.md §5.3）。
///
/// 同一个源的所有 [SourceHttpClient]（源实例、图片加载）共用同一个会话，
/// 因此登录 / 验证得到的 Cookie 对它们都有效。不同源的会话互不相通。
///
/// 用 [SourceSession.persistent] 创建的会话把 Cookie 与 [userAgent] 持久化到
/// [SessionPersistence] 中本源的文件（§5.3「会话持久化」）。
class SourceSession {
  /// 只在内存中的会话。未给出 [cookieJar] 时使用不落盘的 [PersistingCookieJar]。
  SourceSession({CookieJar? cookieJar, DateTime Function()? clock})
    : sourceId = null,
      _persistence = null {
    final jar = cookieJar ?? PersistingCookieJar(clock: clock);
    _jar = jar is PersistingCookieJar ? jar : null;
    this.cookieJar = SecureCookieJar(jar);
    ready = Future.value();
  }

  /// 持久化到 [persistence] 中 [sourceId] 文件的会话。创建时即开始加载，[ready] 完成表示加载结束
  /// （没有文件、文件损坏或读取失败时从空会话开始）。
  SourceSession.persistent(
    String this.sourceId,
    SessionPersistence persistence, {
    DateTime Function()? clock,
  }) : _persistence = persistence {
    final jar = PersistingCookieJar(clock: clock, onChanged: _persist);
    _jar = jar;
    cookieJar = SecureCookieJar(jar);
    ready = persistence.load(sourceId!, _restore);
    jar.ready = ready;
  }

  /// 持久化会话的源 id；内存会话为 null。
  final String? sourceId;
  final SessionPersistence? _persistence;
  PersistingCookieJar? _jar;
  bool _closed = false;
  bool _userAgentChanged = false;

  /// 本源的 Cookie Jar（已包装为 [SecureCookieJar]）。
  late final CookieJar cookieJar;

  /// 持久化的会话加载完成（内存会话立即完成）。读取 [userAgent] 之前应等待它。
  late final Future<void> ready;

  /// WebView 验证时使用的 User-Agent。清单未设置 `User-Agent` 时，本源的请求以它作为默认 UA
  /// （优先级：请求 headers > 清单 headers > 此值）。修改后会持久化。
  String? get userAgent => _userAgent;
  String? _userAgent;
  set userAgent(String? value) {
    if (value == _userAgent) return;
    _userAgent = value;
    _userAgentChanged = true;
    _persist().ignore();
  }

  /// 网络层最近一次检测到人机验证页面的地址（已在白名单内），供「打开验证页」使用。不持久化。
  Uri? lastChallengeUrl;

  /// 「清除 Cookie 与登录状态」：清空本源的 Cookie、User-Agent 与最近挑战地址，并删除持久化文件。
  Future<void> clear() async {
    await ready;
    lastChallengeUrl = null;
    _userAgent = null;
    _userAgentChanged = true;
    // 经 PersistingCookieJar 触发一次写入：空快照 → 删除文件。
    await cookieJar.deleteAll();
  }

  /// 关闭会话（源被删除时）：之后的变更不再写入磁盘，已排队未执行的写入也被放弃。
  void close() => _closed = true;

  bool get isClosed => _closed;

  Future<void> _persist() {
    final persistence = _persistence;
    final jar = _jar;
    if (persistence == null || jar == null || _closed) return Future.value();
    return persistence.write(sourceId!, () {
      if (_closed) return null;
      return SessionSnapshot(cookies: jar.snapshot(), userAgent: _userAgent);
    });
  }

  void _restore(SessionSnapshot snapshot) {
    if (!_userAgentChanged) _userAgent = snapshot.userAgent;
    final dropped = _jar?.restore(snapshot.cookies) ?? 0;
    // 文件里有已过期 / 无效的 Cookie：改写一次，把它们从磁盘上清掉（排在本次加载之后）。
    if (dropped > 0) _persist().ignore();
  }

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

/// 内存中的 `DefaultCookieJar`，另外：
///
/// - 读写前等待 [ready]（持久化会话加载完成）；
/// - 每次变更后调用 [onChanged]（由 [SourceSession] 排队写盘）并等待其完成；
/// - 读取前剔除已过期的 Cookie（`DefaultCookieJar` 会把已过期的 Secure Cookie 发往 https）；
/// - [snapshot] / [restore] 与 [StoredCookie] 互转，`Max-Age` 换算为绝对过期时间。
class PersistingCookieJar implements CookieJar {
  PersistingCookieJar({DateTime Function()? clock, this.onChanged})
    : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  final Future<void> Function()? onChanged;
  final DefaultCookieJar _mem = DefaultCookieJar();

  /// 加载完成前读写都等待它；默认已完成。
  Future<void> ready = Future.value();

  @override
  bool get ignoreExpires => false;

  Future<void> _changed() => onChanged?.call() ?? Future.value();

  @override
  Future<List<Cookie>> loadForRequest(Uri uri) async {
    await ready;
    if (_purgeExpired()) await _changed();
    return _mem.loadForRequest(uri);
  }

  @override
  Future<void> saveFromResponse(Uri uri, List<Cookie> cookies) async {
    await ready;
    if (cookies.isEmpty) return;
    await _mem.saveFromResponse(uri, cookies);
    await _changed();
  }

  @override
  Future<void> delete(Uri uri, [bool withDomainSharedCookie = false]) async {
    await ready;
    await _mem.delete(uri, withDomainSharedCookie);
    await _changed();
  }

  @override
  Future<void> deleteAll() async {
    await ready;
    await _mem.deleteAll();
    await _changed();
  }

  DateTime? _expiryOf(SerializableCookie c) {
    var expires = c.cookie.expires?.toUtc();
    if (c.cookie.maxAge case final maxAge?) {
      final byMaxAge = DateTime.fromMillisecondsSinceEpoch(
        (c.createTimeStamp + maxAge) * 1000,
        isUtc: true,
      );
      if (expires == null || byMaxAge.isBefore(expires)) expires = byMaxAge;
    }
    return expires;
  }

  bool _isExpired(SerializableCookie c, DateTime now) {
    final e = _expiryOf(c);
    return e != null && !e.isAfter(now);
  }

  /// 从内存中删除已过期的 Cookie；有删除时返回 true。
  bool _purgeExpired() {
    final now = _clock();
    var removed = false;
    for (final table in [_mem.hostCookies, _mem.domainCookies]) {
      for (final paths in table.values) {
        for (final byName in paths.values) {
          final before = byName.length;
          byName.removeWhere((_, c) => _isExpired(c, now));
          removed |= byName.length != before;
        }
        paths.removeWhere((_, byName) => byName.isEmpty);
      }
      table.removeWhere((_, paths) => paths.isEmpty);
    }
    return removed;
  }

  /// 当前未过期的全部 Cookie。
  List<StoredCookie> snapshot() {
    final now = _clock();
    return [
      for (final (table, domainCookie) in [
        (_mem.hostCookies, false),
        (_mem.domainCookies, true),
      ])
        for (final MapEntry(key: host, value: paths) in table.entries)
          for (final MapEntry(key: path, value: byName) in paths.entries)
            for (final c in byName.values)
              if (!_isExpired(c, now))
                StoredCookie(
                  host: host,
                  domainCookie: domainCookie,
                  name: c.cookie.name,
                  value: c.cookie.value,
                  path: path,
                  expires: _expiryOf(c),
                  secure: c.cookie.secure,
                  httpOnly: c.cookie.httpOnly,
                ),
    ];
  }

  /// 把持久化的 Cookie 放回内存（不触发写入）；已过期或不合法的被跳过。返回跳过的个数。
  int restore(Iterable<StoredCookie> cookies) {
    final now = _clock();
    var dropped = 0;
    for (final s in cookies) {
      if (s.expires case final e? when !e.isAfter(now)) {
        dropped++;
        continue;
      }
      final Cookie cookie;
      final Uri uri;
      try {
        cookie = Cookie(s.name, s.value)
          ..path = s.path.isEmpty ? '/' : s.path
          ..expires = s.expires
          ..secure = s.secure
          ..httpOnly = s.httpOnly;
        if (s.domainCookie) cookie.domain = s.host;
        uri = Uri(scheme: 'http', host: s.host, path: '/');
      } on FormatException {
        dropped++;
        continue;
      }
      // DefaultCookieJar.saveFromResponse 只操作内存，没有真正的异步工作。
      unawaited(_mem.saveFromResponse(uri, [cookie]));
    }
    return dropped;
  }
}
