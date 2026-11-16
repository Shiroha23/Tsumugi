import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import 'app/app.dart';
import 'features/settings/about/native_licenses.dart';
import 'shared/webview/providers.dart';
import 'sources/registry/providers.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // 视频播放（libmpv，architecture §6.4）。
  MediaKit.ensureInitialized();
  // 原生组件（libmpv / FFmpeg 等）的许可证，「关于 → 第三方许可证」中显示（architecture §6.4.1）。
  registerNativeLicenses();
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
