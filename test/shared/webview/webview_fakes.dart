import 'dart:async';

import 'package:tsumugi/core/network/source_session.dart';
import 'package:tsumugi/shared/webview/source_verification.dart';
import 'package:tsumugi/shared/webview/webview_models.dart';

/// 模拟 WebView 的全局 Cookie 存储：Cookie 带 Domain，按域名匹配返回。
class FakeWebCookieStore implements WebCookieStore {
  final cookies = <WebCookie>[];
  final queried = <Uri>[];
  int clears = 0;
  bool failClear = false;

  @override
  Future<List<WebCookie>> cookiesFor(Uri url) async {
    queried.add(url);
    final host = url.host;
    return [
      for (final c in cookies)
        if (host == c.domain || host.endsWith('.${c.domain}')) c,
    ];
  }

  @override
  Future<void> clearAll() async {
    if (failClear) throw StateError('clear failed');
    clears++;
    cookies.clear();
  }
}

/// 假的验证页：[onOpen] 模拟用户在页面中的操作并给出结果。
class FakeWebViewLauncher implements WebViewLauncher {
  FakeWebViewLauncher([this.onOpen]);

  FutureOr<WebViewOutcome> Function(VerificationRequest request)? onOpen;
  final opened = <VerificationRequest>[];

  @override
  Future<WebViewOutcome> open(VerificationRequest request) async {
    opened.add(request);
    return await onOpen?.call(request) ?? WebViewOutcome.cancelled;
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
