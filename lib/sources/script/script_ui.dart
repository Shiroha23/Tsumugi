import '../../core/network/source_http_client.dart';
import '../../core/network/source_session.dart';
import '../source.dart';

/// 脚本请求打开 WebView（`tsumugi.ui.openWebView`，docs/source-spec.md §4.2）。
class WebViewRequest {
  const WebViewRequest({
    required this.sourceId,
    required this.url,
    required this.cookies,
    this.title,
    this.doneWhenUrlMatches,
  });

  final String sourceId;

  /// 已解析为绝对地址并通过白名单检查。
  final Uri url;

  /// 本源的 HTTP 客户端：用户在 WebView 中完成登录 / 验证后，实现方把 Cookie 写回
  /// [session]（即这个客户端的 Cookie 域），并按 [config] 的白名单过滤主机。
  final SourceHttpClient cookies;

  SourceNetworkConfig get config => cookies.config;
  SourceSession get session => cookies.session;

  final String? title;

  /// WebView 地址匹配此正则时视为完成并关闭；为 null 时由用户手动完成。
  final String? doneWhenUrlMatches;
}

/// 脚本宿主 API `tsumugi.ui` 的 UI 侧实现，由界面层注入。
///
/// 客户端不实现任何自动绕过验证码的逻辑：WebView 只让用户手动完成（architecture §5.3）。
abstract interface class ScriptUi {
  /// 打开 WebView 并在用户完成、Cookie 已写回后返回。用户取消、或因频率限制 / 应用不在前台
  /// 而没有打开时抛出 [SourceErrorCode.challenge] 的 [SourceException]。
  Future<void> openWebView(WebViewRequest request);

  void toast(String sourceId, String message);
}

/// 尚未接入界面时的默认实现：WebView 不可用（`E_UNSUPPORTED`），toast 只写日志。
class UnavailableScriptUi implements ScriptUi {
  const UnavailableScriptUi({this.log});

  final void Function(String message)? log;

  @override
  Future<void> openWebView(WebViewRequest request) async =>
      throw const SourceException(SourceErrorCode.unsupported, 'WebView 尚未接入');

  @override
  void toast(String sourceId, String message) =>
      log?.call('[$sourceId] toast: $message');
}
