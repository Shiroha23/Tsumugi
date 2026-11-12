import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as iaw;

import '../../sources/source.dart';
import 'inappwebview_cookie_store.dart';
import 'url_matcher.dart';
import 'webview_models.dart';

/// 在根 Navigator 上推入 [SourceWebViewPage] 的 [WebViewLauncher]。
class InAppWebViewLauncher implements WebViewLauncher {
  InAppWebViewLauncher({required this.navigatorKey, required this.environment});

  final GlobalKey<NavigatorState> navigatorKey;
  final InAppWebViewEnvironment environment;

  @override
  Future<WebViewOutcome> open(VerificationRequest request) async {
    // 先确认平台可用（Windows 上检查 WebView2 Runtime），失败时抛出 E_UNSUPPORTED。
    final env = await environment.environment;
    final navigator = navigatorKey.currentState;
    if (navigator == null) {
      throw const SourceException(SourceErrorCode.unsupported, '界面尚未就绪');
    }
    final disposed = Completer<void>();
    final outcome = await navigator.push<WebViewOutcome>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => SourceWebViewPage(
          request: request,
          environment: env,
          onDisposed: () {
            if (!disposed.isCompleted) disposed.complete();
          },
        ),
      ),
    );
    // push 的 Future 在 pop 时就完成，此时页面（与原生 WebView）还在退出动画中，仍可能写入 Cookie。
    // 等页面销毁后再交给调用方同步并清空 Cookie 存储，避免旧页面的写入落到清空之后。
    await disposed.future
        .timeout(const Duration(seconds: 5))
        .then<void>((_) {}, onError: (Object _) {});
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return outcome ?? WebViewOutcome.cancelled;
  }
}

/// 让用户**手动**完成验证 / 登录的页面（docs/architecture.md §5.3）。
///
/// 不在页面中注入或执行任何脚本（完成时读取 `navigator.userAgent` 除外），不自动填写或点击。
/// 主框架导航到白名单外的地址时阻止并提示；子资源与 iframe 不限制。
class SourceWebViewPage extends StatefulWidget {
  const SourceWebViewPage({
    super.key,
    required this.request,
    this.environment,
    this.onDisposed,
  });

  final VerificationRequest request;
  final iaw.WebViewEnvironment? environment;

  /// 页面（及其原生 WebView）销毁时调用。
  final VoidCallback? onDisposed;

  @override
  State<SourceWebViewPage> createState() => _SourceWebViewPageState();
}

class _SourceWebViewPageState extends State<SourceWebViewPage> {
  iaw.InAppWebViewController? _controller;
  late final UrlMatcher? _matcher = switch (widget.request.doneWhenUrlMatches) {
    final p? => UrlMatcher(p),
    null => null,
  };
  final _visited = <Uri>{};
  Uri? _current;
  String? _pageTitle;
  int _progress = 0;

  /// 最近一次被阻止的主框架地址的主机。
  String? _blockedHost;

  /// 当前主框架停在白名单外的页面上（未经 shouldOverrideUrlLoading 就开始加载的情况）。
  bool _offList = false;

  /// 已 pop（完成或取消）。
  bool _finished = false;

  /// 正在完成（读取 UA）；期间仍可取消。
  bool _finishing = false;

  @override
  void dispose() {
    unawaited(_controller?.stopLoading().catchError((Object _) {}));
    widget.onDisposed?.call();
    super.dispose();
  }

  VerificationRequest get _req => widget.request;

  bool _allowed(Uri? url) =>
      url != null &&
      (_req.policy.isAllowed(url) || url.toString() == 'about:blank');

  void _block(Uri? url) {
    if (!mounted) return;
    setState(
      () => _blockedHost = url?.host.isNotEmpty == true ? url!.host : '$url',
    );
  }

  /// 主框架地址变化（开始加载 / 历史更新 / 加载完成）。白名单检查对所有事件生效；
  /// `doneWhenUrlMatches` 只在 [loaded]（加载完成，响应与页面脚本的 Cookie 均已写入）时判断。
  Future<void> _onMainFrameUrl(Uri? url, {bool loaded = false}) async {
    if (url == null || !mounted || _finished) return;
    if (!_allowed(url)) {
      setState(() => _offList = true);
      _block(url);
      unawaited(_controller?.stopLoading());
      return;
    }
    if (url.scheme == 'http' || url.scheme == 'https') {
      _visited.add(url.removeFragment());
    }
    setState(() {
      _current = url;
      _offList = false;
    });
    final matcher = _matcher;
    if (!loaded ||
        matcher == null ||
        !(url.scheme == 'http' || url.scheme == 'https')) {
      return;
    }
    final matched = await matcher.matches(url.toString());
    // 求值期间页面可能已导航到别处。
    if (matched && mounted && _current == url && !_offList) await _finish();
  }

  Future<void> _finish() async {
    if (_finished || _finishing || !mounted) return;
    if (_offList) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('当前页面不在源的白名单内，请先返回')));
      return;
    }
    _finishing = true;
    String? ua;
    try {
      final r = await _controller
          ?.evaluateJavascript(source: 'navigator.userAgent')
          .timeout(const Duration(seconds: 2));
      if (r is String) ua = r;
    } on Object {
      // 读取失败或超时时不同步 UA。
    }
    _finishing = false;
    // 等待期间用户可能已取消。
    if (!mounted || _finished) return;
    _finished = true;
    Navigator.of(context).pop(
      WebViewOutcome(completed: true, visited: {..._visited}, userAgent: ua),
    );
  }

  void _cancel() {
    if (_finished) return;
    _finished = true;
    Navigator.of(context).pop(WebViewOutcome.cancelled);
  }

  Future<void> _backToStart() async {
    await _controller?.loadUrl(
      urlRequest: iaw.URLRequest(url: iaw.WebUri.uri(_req.url)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final host = (_current ?? _req.url).host;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _cancel();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.close),
            tooltip: '取消',
            onPressed: _cancel,
          ),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _req.title ?? _pageTitle ?? '验证 / 登录',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                host,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: '刷新',
              onPressed: () => _controller?.reload(),
            ),
            TextButton(onPressed: _finish, child: const Text('完成')),
          ],
          bottom: _progress > 0 && _progress < 100
              ? PreferredSize(
                  preferredSize: const Size.fromHeight(2),
                  child: LinearProgressIndicator(
                    value: _progress / 100,
                    minHeight: 2,
                  ),
                )
              : null,
        ),
        body: Column(
          children: [
            Material(
              color: theme.colorScheme.surfaceContainerHighest,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _req.doneWhenUrlMatches == null
                            ? '请在下方页面中手动完成验证或登录，然后点右上角「完成」。'
                            : '请在下方页面中手动完成验证或登录，完成后将自动关闭。',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (_blockedHost case final blocked?)
              MaterialBanner(
                leading: Icon(Icons.block, color: theme.colorScheme.error),
                content: Text('已阻止跳转到白名单外的地址：$blocked'),
                actions: [
                  TextButton(
                    onPressed: () => setState(() => _blockedHost = null),
                    child: const Text('知道了'),
                  ),
                ],
              ),
            Expanded(
              child: Stack(
                children: [
                  iaw.InAppWebView(
                    webViewEnvironment: widget.environment,
                    initialUrlRequest: iaw.URLRequest(
                      url: iaw.WebUri.uri(_req.url),
                    ),
                    initialSettings: iaw.InAppWebViewSettings(
                      userAgent: _req.userAgent ?? '',
                      useShouldOverrideUrlLoading: true,
                      javaScriptCanOpenWindowsAutomatically: false,
                      supportMultipleWindows: false,
                      thirdPartyCookiesEnabled: true,
                    ),
                    onWebViewCreated: (c) => _controller = c,
                    shouldOverrideUrlLoading: (c, action) async {
                      final url = action.request.url;
                      if (action.isForMainFrame && !_allowed(url)) {
                        _block(url);
                        return iaw.NavigationActionPolicy.CANCEL;
                      }
                      return iaw.NavigationActionPolicy.ALLOW;
                    },
                    onLoadStart: (c, url) => _onMainFrameUrl(url),
                    onLoadStop: (c, url) => _onMainFrameUrl(url, loaded: true),
                    onUpdateVisitedHistory: (c, url, _) => _onMainFrameUrl(url),
                    onTitleChanged: (c, title) {
                      if (mounted) setState(() => _pageTitle = title);
                    },
                    onProgressChanged: (c, p) {
                      if (mounted) setState(() => _progress = p);
                    },
                  ),
                  if (_offList)
                    Positioned.fill(
                      child: ColoredBox(
                        color: theme.colorScheme.surface,
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.block,
                                size: 48,
                                color: theme.colorScheme.error,
                              ),
                              const SizedBox(height: 12),
                              const Text('该页面不在源的白名单内，已停止加载'),
                              const SizedBox(height: 12),
                              FilledButton.tonal(
                                onPressed: _backToStart,
                                child: const Text('返回起始页'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
