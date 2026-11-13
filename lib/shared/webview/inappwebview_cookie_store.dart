import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart' as iaw;
import 'package:path_provider/path_provider.dart';

import '../../core/network/source_session.dart';
import '../../sources/source.dart';
import 'webview_models.dart';

/// 本应用支持 WebView 的平台。
bool get webViewSupported =>
    Platform.isWindows || Platform.isAndroid || Platform.isIOS;

/// Windows 上 WebView2 的运行环境：用户数据目录放在应用支持目录下
/// （默认位置在 exe 旁边，安装到只读目录时会失败）。其他平台为 null。
class InAppWebViewEnvironment {
  Future<iaw.WebViewEnvironment?>? _env;

  Future<iaw.WebViewEnvironment?> get environment => _env ??= _create().then(
    (e) => e,
    onError: (Object e) {
      _env = null; // 允许下次重试（例如用户刚安装了 WebView2 Runtime）
      throw e;
    },
  );

  Future<iaw.WebViewEnvironment?> _create() async {
    if (!webViewSupported) {
      throw const SourceException(
        SourceErrorCode.unsupported,
        '此平台不支持 WebView',
      );
    }
    if (!Platform.isWindows) return null;
    final version = await iaw.WebViewEnvironment.getAvailableVersion();
    if (version == null) {
      throw const SourceException(
        SourceErrorCode.unsupported,
        '未安装 Microsoft Edge WebView2 Runtime，无法打开验证页',
      );
    }
    final support = await getApplicationSupportDirectory();
    return iaw.WebViewEnvironment.create(
      settings: iaw.WebViewEnvironmentSettings(
        userDataFolder: '${support.path}${Platform.pathSeparator}webview2',
      ),
    );
  }
}

/// 基于 flutter_inappwebview `CookieManager` 的 [WebCookieStore]：打开验证页前 / 销毁后清空。
class InAppWebCookieStore implements WebCookieStore {
  InAppWebCookieStore(this._environment);

  final InAppWebViewEnvironment _environment;

  @override
  Future<void> clearAll() async {
    final manager = iaw.CookieManager.instance(
      webViewEnvironment: await _environment.environment,
    );
    final ok = await manager.deleteAllCookies();
    // 返回值的含义因平台而异：Windows 上 false 表示 CDP 调用失败，必须视为失败，
    // 否则验证页可能带着其他源的 Cookie 打开；Android 的 removeAllCookies 回调值只表示
    // “是否删掉了 Cookie”，存储本来为空时也是 false，不能当作失败。
    if (!ok && Platform.isWindows) {
      throw StateError('deleteAllCookies returned false');
    }
  }
}

/// 经存活的验证页读取 / 清空 Cookie（[LiveWebView]）。
///
/// Windows 上直接对该页面的 WebView2 调用 CDP（`Network.getCookies` / `Network.clearBrowserCookies`），
/// 失败时插件抛出错误；不用 `CookieManager`，因为它经临时 WebView2 读取，失败时只返回空列表。
/// 其他平台用 `CookieManager`（进程级存储，与页面共享）。
class InAppLiveWebView implements LiveWebView {
  InAppLiveWebView(this.controller, this.environment);

  final iaw.InAppWebViewController? controller;
  final iaw.WebViewEnvironment? environment;

  iaw.InAppWebViewController get _controller =>
      controller ?? (throw StateError('WebView 尚未创建'));

  @override
  Future<List<WebCookie>> cookiesFor(Uri url) async {
    if (Platform.isWindows) {
      final result = await _controller.callDevToolsProtocolMethod(
        methodName: 'Network.getCookies',
        parameters: {
          'urls': [url.toString()],
        },
      );
      return cdpCookies(result, url);
    }
    final manager = iaw.CookieManager.instance(webViewEnvironment: environment);
    final list = await manager.getCookies(
      url: iaw.WebUri.uri(url),
      webViewController: _controller,
    );
    return [for (final c in list) ?_convert(c, url)];
  }

  @override
  Future<void> clearCookies() async {
    if (Platform.isWindows) {
      await _controller.callDevToolsProtocolMethod(
        methodName: 'Network.clearBrowserCookies',
      );
      return;
    }
    await iaw.CookieManager.instance(webViewEnvironment: environment)
        .deleteAllCookies();
  }

  /// 平台没给出的属性（Android 无 `GET_COOKIE_INFO` 时只有 name / value）按收紧的方向补全：
  /// Path 取读取时的地址路径，经 https 读到的视为 Secure。
  static WebCookie? _convert(iaw.Cookie c, Uri url) {
    final value = c.value;
    if (value == null) return null;
    final raw = c.expiresDate;
    return WebCookie(
      name: c.name,
      value: '$value',
      domain: c.domain,
      path: c.path ?? (url.path.isEmpty ? '/' : url.path),
      // Android / iOS 为毫秒；≤ 0 表示会话 Cookie。
      expires: c.isSessionOnly == true || raw == null || raw <= 0
          ? null
          : DateTime.fromMillisecondsSinceEpoch(raw, isUtc: true),
      secure: c.isSecure ?? url.scheme == 'https',
      httpOnly: c.isHttpOnly ?? false,
    );
  }
}

/// 解析 CDP `Network.getCookies` 的结果（`{cookies: [{name, value, domain, path, expires(秒), httpOnly, secure, session}]}`）。
/// 结构不符时抛出 [FormatException]，不返回空列表。
List<WebCookie> cdpCookies(Object? result, Uri url) {
  if (result is! Map || result['cookies'] is! List) {
    throw FormatException('unexpected Network.getCookies result: $result');
  }
  return [
    for (final c in result['cookies'] as List)
      if (c is Map && c['name'] is String && c['value'] is String)
        WebCookie(
          name: c['name'] as String,
          value: c['value'] as String,
          domain: c['domain'] as String?,
          path: (c['path'] as String?) ?? (url.path.isEmpty ? '/' : url.path),
          expires: c['session'] == true
              ? null
              : switch (c['expires']) {
                  final num e when e > 0 => DateTime.fromMillisecondsSinceEpoch(
                    (e * 1000).round(),
                    isUtc: true,
                  ),
                  _ => null,
                },
          secure: c['secure'] == true,
          httpOnly: c['httpOnly'] == true,
        ),
  ];
}
