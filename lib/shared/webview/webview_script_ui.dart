import '../../sources/script/script_ui.dart';
import '../../sources/source.dart';
import 'source_verifier.dart';
import 'webview_models.dart';
import 'webview_throttle.dart';

/// 脚本宿主 API `tsumugi.ui` 的界面实现（docs/source-spec.md §4.2、architecture §5.3）。
///
/// `openWebView` 经 [SourceVerifier] 以「脚本发起」的身份打开（受前台检查与频率限制），
/// 用户完成后 Cookie 已写回本源；用户取消时抛出 `E_CHALLENGE`。
class WebViewScriptUi implements ScriptUi {
  WebViewScriptUi({
    required this.verifier,
    required this.showToast,
    bool Function()? isForeground,
    ToastThrottle? toastThrottle,
  }) : _isForeground = isForeground ?? _always,
       _toasts = toastThrottle ?? ToastThrottle();

  final SourceVerifier verifier;

  /// 实际显示一条 toast（例如经 `ScaffoldMessenger` 显示 SnackBar）。
  final void Function(String sourceId, String message) showToast;
  final bool Function() _isForeground;
  final ToastThrottle _toasts;

  static bool _always() => true;

  @override
  Future<void> openWebView(WebViewRequest request) async {
    final completed = await verifier.verify(
      VerificationRequest.fromConfig(
        request.config,
        url: request.url,
        title: request.title,
        doneWhenUrlMatches: request.doneWhenUrlMatches,
      ),
      request.session,
      userInitiated: false,
    );
    if (!completed) {
      throw const SourceException(SourceErrorCode.challenge, '用户取消了验证');
    }
  }

  @override
  void toast(String sourceId, String message) {
    if (message.isEmpty || !_isForeground()) return;
    if (!_toasts.tryAcquire(sourceId)) return;
    showToast(sourceId, message);
  }
}
