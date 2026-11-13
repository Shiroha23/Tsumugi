import '../../core/network/host_policy.dart';
import '../../core/network/source_http_client.dart';
import '../../core/network/source_session.dart';

/// 一次 WebView 验证 / 登录（docs/architecture.md §5.3）。
class VerificationRequest {
  VerificationRequest({
    required this.sourceId,
    required this.url,
    required this.baseUrl,
    required this.policy,
    this.allowedHosts = const [],
    this.userAgent,
    this.title,
    this.doneWhenUrlMatches,
  });

  /// 由源的网络配置构造：白名单、`baseUrl` 与清单 `User-Agent` 都取自 [config]。
  factory VerificationRequest.fromConfig(
    SourceNetworkConfig config, {
    required Uri url,
    String? title,
    String? doneWhenUrlMatches,
  }) => VerificationRequest(
    sourceId: config.sourceId,
    url: url,
    baseUrl: config.baseUrl,
    policy: config.hostPolicy,
    allowedHosts: config.allowedHosts,
    userAgent: config.defaultHeaders.entries
        .where((e) => e.key.toLowerCase() == 'user-agent')
        .map((e) => e.value)
        .where((v) => v.isNotEmpty)
        .firstOrNull,
    title: title,
    doneWhenUrlMatches: doneWhenUrlMatches,
  );

  final String sourceId;

  /// 起始地址，必须通过 [policy]。
  final Uri url;
  final Uri baseUrl;

  /// 源的白名单：主框架导航与 Cookie 同步都只限于此。
  final HostPolicy policy;

  /// 清单的 `allowedHosts`（同步 Cookie 时会读取其中非通配主机的 Cookie）。
  final List<String> allowedHosts;

  /// 清单设置的 `User-Agent`；WebView 使用同一个 UA。为 null 时用 WebView 默认 UA，
  /// 完成后记入会话（[SourceSession.userAgent]）。
  final String? userAgent;

  final String? title;

  /// 主框架地址匹配此正则时自动完成。
  final String? doneWhenUrlMatches;
}

/// WebView 页面关闭时的结果。
class WebViewOutcome {
  const WebViewOutcome({
    required this.completed,
    this.visited = const {},
    this.userAgent,
  });

  static const cancelled = WebViewOutcome(completed: false);

  /// 用户点了「完成」或命中 `doneWhenUrlMatches`；false 表示取消。
  final bool completed;

  /// 主框架访问过的、在白名单内的地址。
  final Set<Uri> visited;

  /// WebView 实际使用的 `navigator.userAgent`。
  final String? userAgent;
}

/// 验证页仍然存活时对其 Cookie 的访问（只在 [CompletionHandler] 执行期间有效）。
///
/// 必须在页面关闭 / 销毁**之前**读取：Windows 上 WebView 销毁后插件经临时 WebView2 读取，
/// 失败（如 `ERROR_NOT_READY`）时只返回空列表，无法与“没有 Cookie”区分。
abstract interface class LiveWebView {
  /// 会发往 [url] 的 Cookie（含 HttpOnly）。读取失败时抛出异常，不返回空列表。
  Future<List<WebCookie>> cookiesFor(Uri url);

  /// 清空 WebView 的全部 Cookie（同步完成后、页面关闭前调用）。
  Future<void> clearCookies();
}

/// 用户完成时、页面关闭前由验证页调用：同步 Cookie 并返回写入的数量。
/// 抛出异常时页面不关闭，提示用户重试或取消。
typedef CompletionHandler = Future<int> Function(
  WebViewOutcome outcome,
  LiveWebView webView,
);

/// 显示验证页的界面层；测试中用假实现，不启动真实 WebView。
abstract interface class WebViewLauncher {
  /// 显示验证页并等待用户完成或关闭。用户完成时，页面在关闭前调用 [onComplete]，
  /// 成功后才关闭；取消时不调用。平台不支持 WebView 时抛出 `SourceException(E_UNSUPPORTED)`。
  Future<WebViewOutcome> open(
    VerificationRequest request, {
    required CompletionHandler onComplete,
  });
}

/// WebView 的（全局）Cookie 存储：打开验证页前 / 结束后清空。
abstract interface class WebCookieStore {
  /// 清空 WebView 的全部 Cookie。
  Future<void> clearAll();
}
