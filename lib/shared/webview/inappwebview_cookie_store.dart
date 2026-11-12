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

/// 基于 flutter_inappwebview `CookieManager` 的 [WebCookieStore]（读取含 HttpOnly 的 Cookie）。
class InAppWebCookieStore implements WebCookieStore {
  InAppWebCookieStore(this._environment);

  final InAppWebViewEnvironment _environment;

  Future<iaw.CookieManager> _manager() async => iaw.CookieManager.instance(
    webViewEnvironment: await _environment.environment,
  );

  @override
  Future<List<WebCookie>> cookiesFor(Uri url) async {
    final manager = await _manager();
    final list = await manager.getCookies(url: iaw.WebUri.uri(url));
    return [for (final c in list) ?_convert(c, url)];
  }

  @override
  Future<void> clearAll() async {
    final manager = await _manager();
    final ok = await manager.deleteAllCookies();
    // 返回值的含义因平台而异：Windows 上 false 表示 CDP 调用失败，必须视为失败，
    // 否则验证页可能带着其他源的 Cookie 打开；Android 的 removeAllCookies 回调值只表示
    // “是否删掉了 Cookie”，存储本来为空时也是 false，不能当作失败。
    if (!ok && Platform.isWindows) {
      throw StateError('deleteAllCookies returned false');
    }
  }

  /// 平台没给出的属性（Android 无 `GET_COOKIE_INFO` 时只有 name / value）按收紧的方向补全：
  /// Path 取读取时的地址路径，经 https 读到的视为 Secure。
  static WebCookie? _convert(iaw.Cookie c, Uri url) {
    final value = c.value;
    if (value == null) return null;
    return WebCookie(
      name: c.name,
      value: '$value',
      domain: c.domain,
      path: c.path ?? (url.path.isEmpty ? '/' : url.path),
      expires: c.isSessionOnly == true ? null : _expires(c.expiresDate),
      secure: c.isSecure ?? url.scheme == 'https',
      httpOnly: c.isHttpOnly ?? false,
    );
  }

  /// Windows（CDP `Network.getCookies`）给出的是秒，Android / iOS 为毫秒；≤ 0 表示会话 Cookie。
  static DateTime? _expires(int? raw) {
    if (raw == null || raw <= 0) return null;
    final ms = Platform.isWindows ? raw * 1000 : raw;
    return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  }
}
