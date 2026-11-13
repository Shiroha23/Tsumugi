import 'package:flutter/material.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../sources/registry/providers.dart';
import '../../sources/script/script_ui.dart';
import '../../sources/session/source_sessions.dart';
import 'inappwebview_cookie_store.dart';
import 'inappwebview_page.dart';
import 'source_verification.dart';
import 'source_verifier.dart';
import 'webview_models.dart';
import 'webview_script_ui.dart';

export 'source_verification.dart';
export 'source_verifier.dart';
export 'webview_models.dart';

part 'providers.g.dart';

/// 根 Navigator（`GoRouter.navigatorKey`）：验证页推入其中，脚本发起时也无需 BuildContext。
@Riverpod(keepAlive: true)
GlobalKey<NavigatorState> rootNavigatorKey(Ref ref) =>
    GlobalKey<NavigatorState>(debugLabel: 'root');

/// 根 ScaffoldMessenger（`MaterialApp.scaffoldMessengerKey`），用于 `tsumugi.ui.toast`。
@Riverpod(keepAlive: true)
GlobalKey<ScaffoldMessengerState> rootMessengerKey(Ref ref) =>
    GlobalKey<ScaffoldMessengerState>(debugLabel: 'messenger');

/// 应用是否在前台（脚本只能在用户可见时弹出验证页 / toast）。
@Riverpod(keepAlive: true)
bool Function() appInForeground(Ref ref) => () {
  final state = WidgetsBinding.instance.lifecycleState;
  return state == null || state == AppLifecycleState.resumed;
};

@Riverpod(keepAlive: true)
InAppWebViewEnvironment inAppWebViewEnvironment(Ref ref) =>
    InAppWebViewEnvironment();

@Riverpod(keepAlive: true)
WebViewLauncher webViewLauncher(Ref ref) => InAppWebViewLauncher(
  navigatorKey: ref.watch(rootNavigatorKeyProvider),
  environment: ref.watch(inAppWebViewEnvironmentProvider),
);

@Riverpod(keepAlive: true)
WebCookieStore webCookieStore(Ref ref) =>
    InAppWebCookieStore(ref.watch(inAppWebViewEnvironmentProvider));

@Riverpod(keepAlive: true)
SourceVerifier sourceVerifier(Ref ref) => SourceVerifier(
  launcher: ref.watch(webViewLauncherProvider),
  cookies: ref.watch(webCookieStoreProvider),
  isForeground: ref.watch(appInForegroundProvider),
  log: (m) => debugPrint('[webview] $m'),
);

@Riverpod(keepAlive: true)
SourceVerification sourceVerification(Ref ref) => RegistrySourceVerification(
  registry: ref.watch(sourceRegistryProvider),
  sessions: ref.watch(sourceSessionsProvider),
  verifier: ref.watch(sourceVerifierProvider),
);

/// 覆盖 `scriptUiProvider` 用的界面实现（见 `lib/main.dart`）。
@Riverpod(keepAlive: true)
ScriptUi webViewScriptUi(Ref ref) {
  final messenger = ref.watch(rootMessengerKeyProvider);
  return WebViewScriptUi(
    verifier: ref.watch(sourceVerifierProvider),
    isForeground: ref.watch(appInForegroundProvider),
    showToast: (sourceId, message) {
      final state = messenger.currentState;
      if (state == null) return;
      state
        ..hideCurrentSnackBar()
        // 标明来源，避免源脚本的提示被误认为应用自身的提示。
        ..showSnackBar(SnackBar(content: Text('[$sourceId] $message')));
    },
  );
}
