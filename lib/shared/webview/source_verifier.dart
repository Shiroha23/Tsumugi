import 'dart:async';

import '../../core/network/source_session.dart';
import '../../sources/source.dart';
import 'webview_models.dart';
import 'webview_throttle.dart';

/// 编排一次 WebView 验证 / 登录（docs/architecture.md §5.3）：
///
/// 1. 清空 WebView 的 Cookie（WebView 存储是全局的，避免看到其他源的 Cookie）；
/// 2. 显示验证页，等待用户**手动**完成或取消；
/// 3. 用户完成时、**页面关闭前**（WebView 仍存活）读取白名单内主机的 Cookie，写入该源的
///    [SourceSession]，必要时记下 WebView 的 UA，并清空 WebView 的 Cookie；
/// 4. 页面销毁后再次清空 WebView 的 Cookie（兜底）。
///
/// 同一时刻只显示一个验证页：同一源的并发请求共用进行中的那一次，其他源的请求被拒绝。
/// 脚本发起的打开（`userInitiated: false`）还受前台检查与 [WebViewThrottle] 限制。
class SourceVerifier {
  SourceVerifier({
    required this.launcher,
    required this.cookies,
    bool Function()? isForeground,
    WebViewThrottle? throttle,
    void Function(String message)? log,
  }) : _isForeground = isForeground ?? _always,
       throttle = throttle ?? WebViewThrottle(),
       _log = log ?? _ignore;

  final WebViewLauncher launcher;
  final WebCookieStore cookies;
  final WebViewThrottle throttle;
  final bool Function() _isForeground;
  final void Function(String message) _log;

  static bool _always() => true;
  static void _ignore(String _) {}

  _InFlight? _inFlight;

  /// 是否有验证页正在显示。
  bool get busy => _inFlight != null;

  /// 显示验证页；用户完成（Cookie 已写回 [session]）时返回 true，取消时返回 false。
  ///
  /// 因前台检查、频率限制或已有其他源的验证页而没有显示时，抛出
  /// `SourceException(E_CHALLENGE)`；起始地址不在白名单内时抛出 `E_HOST_NOT_ALLOWED`。
  Future<bool> verify(
    VerificationRequest request,
    SourceSession session, {
    required bool userInitiated,
  }) {
    if (!request.policy.isAllowed(request.url)) {
      return Future.error(
        const SourceException(SourceErrorCode.hostNotAllowed, '验证页地址不在源的白名单内'),
      );
    }
    if (_inFlight case final current?) {
      if (current.sourceId == request.sourceId) return current.future;
      return Future.error(
        const SourceException(SourceErrorCode.challenge, '已有其他源的验证页打开'),
      );
    }
    if (!userInitiated) {
      if (!_isForeground()) {
        return Future.error(
          const SourceException(SourceErrorCode.challenge, '应用不在前台，未打开验证页'),
        );
      }
      if (throttle.blockedFor(request.sourceId) case final left?) {
        return Future.error(
          SourceException(
            SourceErrorCode.challenge,
            '验证页打开过于频繁，请 ${left.inSeconds + 1} 秒后再试',
          ),
        );
      }
    }
    final future = _run(request, session, userInitiated: userInitiated);
    final entry = _InFlight(request.sourceId, future);
    _inFlight = entry;
    future.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
      if (identical(_inFlight, entry)) _inFlight = null;
    });
    return future;
  }

  Future<bool> _run(
    VerificationRequest request,
    SourceSession session, {
    required bool userInitiated,
  }) async {
    // 清空失败时无法保证隔离，不打开验证页。
    try {
      await cookies.clearAll();
    } on Object catch (e) {
      _log('clear WebView cookies failed: $e');
      throw const SourceException(
        SourceErrorCode.unsupported,
        '无法清空 WebView 的 Cookie',
      );
    }
    var synced = false;
    try {
      final outcome = await launcher.open(
        request,
        onComplete: (outcome, webView) async {
          final count = await _sync(request, session, outcome, webView);
          synced = true;
          try {
            await webView.clearCookies();
          } on Object catch (e) {
            _log('clear live WebView cookies failed: $e');
          }
          return count;
        },
      );
      // 冷却只针对脚本打开过的验证页（source-spec §4.2）；用户主动打开与未能显示的情况不计。
      if (!userInitiated) {
        throttle.record(request.sourceId, completed: outcome.completed);
      }
      if (outcome.completed && !synced) {
        throw const SourceException(
          SourceErrorCode.unsupported,
          '验证页关闭前没有同步 Cookie',
        );
      }
      return outcome.completed;
    } finally {
      try {
        await cookies.clearAll();
      } on Object catch (e) {
        _log('clear WebView cookies failed: $e');
      }
    }
  }

  /// 读取白名单内地址的 Cookie 并写入 [session]，返回写入数量。
  /// 任一地址读取失败时抛出 `SourceException`（不当作 0 个）。
  Future<int> _sync(
    VerificationRequest request,
    SourceSession session,
    WebViewOutcome outcome,
    LiveWebView webView,
  ) async {
    final policy = request.policy;
    final targets = <Uri>{
      _root(request.baseUrl),
      for (final host in request.allowedHosts)
        if (!host.startsWith('*.')) ?_tryRoot(request.baseUrl.scheme, host),
      request.url.removeFragment(),
      for (final u in outcome.visited) u.removeFragment(),
    }.where(policy.isAllowed);

    var total = 0;
    // 同一 Cookie 常在多个地址（根路径、起始页、访问过的页面）上都能读到，每台主机只写入一次。
    final seen = <String>{};
    for (final target in targets) {
      final List<WebCookie> found;
      try {
        found = await webView.cookiesFor(target);
      } on Object catch (e) {
        _log('[${request.sourceId}] read cookies for $target failed: $e');
        throw SourceException(
          SourceErrorCode.unsupported,
          '读取验证页 Cookie 失败（${target.host}）：$e',
        );
      }
      final fresh = [
        for (final c in found)
          if (seen.add(
            '${target.host};${c.name};${c.path == null || c.path!.isEmpty ? '/' : c.path}',
          ))
            c,
      ];
      total += await session.importCookies(target, fresh, policy);
    }
    _log('[${request.sourceId}] synced $total cookie(s) from WebView');
    if (total == 0) {
      _log('[${request.sourceId}] warning: no cookies found for $targets');
    }

    if (request.userAgent == null) {
      final ua = outcome.userAgent?.trim();
      if (ua != null && ua.isNotEmpty && ua.length <= 1024) {
        session.userAgent = ua;
      }
    }
    session.lastChallengeUrl = null;
    return total;
  }

  static Uri _root(Uri u) => Uri(
    scheme: u.scheme,
    host: u.host,
    port: u.hasPort ? u.port : null,
    path: '/',
  );

  static Uri? _tryRoot(String scheme, String host) {
    try {
      return Uri(scheme: scheme, host: host, path: '/');
    } on FormatException {
      return null;
    }
  }
}

/// 进行中的一次验证（类实例有稳定的身份，可用 [identical] 比较；record 没有）。
final class _InFlight {
  _InFlight(this.sourceId, this.future);

  final String sourceId;
  final Future<bool> future;
}
