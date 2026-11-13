import 'dart:async';

import 'package:tsumugi/core/network/source_session.dart';
import 'package:tsumugi/shared/webview/source_verification.dart';
import 'package:tsumugi/shared/webview/webview_models.dart';

/// 调用顺序记录（open / read / sync / clear / closed …），用于断言“先同步、后关闭”。
typedef EventLog = List<String>;

/// 模拟 WebView 的 Cookie 存储：既是全局存储（[clearAll]），也是存活页面的读取接口
/// （[cookiesFor] / [clearCookies]）。Cookie 带 Domain，按域名匹配返回。
class FakeWebCookieStore implements WebCookieStore, LiveWebView {
  FakeWebCookieStore([EventLog? events]) : events = events ?? [];

  final EventLog events;
  final cookies = <WebCookie>[];
  final queried = <Uri>[];
  int clears = 0;
  bool failClear = false;

  /// 为 true 时读取抛错（模拟 WebView 已销毁 / CDP 失败）。
  bool failReads = false;

  /// 页面是否仍存活；为 false 时读取抛错（真实插件在页面销毁后无法可靠读取）。
  bool alive = false;

  @override
  Future<List<WebCookie>> cookiesFor(Uri url) async {
    events.add('read ${url.host}');
    if (failReads) throw StateError('ERROR_NOT_READY');
    if (!alive) throw StateError('WebView is not alive');
    queried.add(url);
    final host = url.host;
    return [
      for (final c in cookies)
        if (host == c.domain || host.endsWith('.${c.domain}')) c,
    ];
  }

  @override
  Future<void> clearCookies() async {
    events.add('clear live');
    cookies.clear();
  }

  @override
  Future<void> clearAll() async {
    events.add('clear');
    if (failClear) throw StateError('clear failed');
    clears++;
    cookies.clear();
  }
}

/// 假的验证页，行为与真实页面一致：[onOpen] 模拟用户操作；结果为“完成”时在关闭前调用
/// `onComplete`（页面仍存活），同步失败时页面不关闭——这里视为用户随后关闭（取消）。
class FakeWebViewLauncher implements WebViewLauncher {
  FakeWebViewLauncher([this.onOpen, FakeWebCookieStore? live]) : _live = live;

  FutureOr<WebViewOutcome> Function(VerificationRequest request)? onOpen;
  FakeWebCookieStore? _live;
  set live(FakeWebCookieStore value) => _live = value;

  /// 为 true 时模拟有缺陷的页面：完成后不调用 onComplete 就关闭。
  bool skipComplete = false;

  final opened = <VerificationRequest>[];
  final syncErrors = <Object>[];
  final syncedCounts = <int>[];

  @override
  Future<WebViewOutcome> open(
    VerificationRequest request, {
    required CompletionHandler onComplete,
  }) async {
    opened.add(request);
    final live = _live ?? (throw StateError('FakeWebViewLauncher.live 未设置'));
    live
      ..events.add('open')
      ..alive = true;
    try {
      final outcome = await onOpen?.call(request) ?? WebViewOutcome.cancelled;
      if (outcome.completed && !skipComplete) {
        try {
          syncedCounts.add(await onComplete(outcome, live));
        } on Object catch (e) {
          syncErrors.add(e);
          return WebViewOutcome.cancelled;
        }
      }
      return outcome;
    } finally {
      live
        ..alive = false
        ..events.add('closed');
    }
  }
}

/// 可手动推进的时钟。
class FakeClock {
  DateTime now = DateTime.utc(2026, 11, 12, 12);
  DateTime call() => now;
  void advance(Duration d) => now = now.add(d);
}

/// 假的「打开验证页」入口：记录调用并返回 [result]。
class FakeSourceVerification implements SourceVerification {
  FakeSourceVerification({this.result = true});

  bool result;
  Object? error;

  /// 非 null 时等待它完成（模拟用户仍在验证页中）。
  Completer<bool>? pending;
  final calls = <String>[];

  @override
  Future<bool> verifySource(String sourceId) async {
    calls.add(sourceId);
    if (error case final e?) throw e;
    if (pending case final p?) return p.future;
    return result;
  }
}
