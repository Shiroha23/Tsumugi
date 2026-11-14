import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import 'app/app.dart';
import 'shared/webview/providers.dart';
import 'sources/registry/providers.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // 视频播放（libmpv，architecture §6.4）。
  MediaKit.ensureInitialized();
  runApp(
    ProviderScope(
      overrides: [
        // 脚本宿主 API `tsumugi.ui` 接入 WebView 验证页与 SnackBar（architecture §5.3）。
        scriptUiProvider.overrideWith(
          (ref) => ref.watch(webViewScriptUiProvider),
        ),
      ],
      child: const TsumugiApp(),
    ),
  );
}
