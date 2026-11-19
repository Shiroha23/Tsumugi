import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../shared/download/providers.dart';
import '../shared/sync/providers.dart';
import '../shared/webview/providers.dart';
import '../sources/repository/providers.dart';
import 'router.dart';
import 'theme.dart';

class TsumugiApp extends ConsumerWidget {
  const TsumugiApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 规则仓库：启动时与每 24 h 检查更新（architecture §4.4）。
    ref.watch(repositoryUpdateSchedulerProvider);
    // 启动下载队列：继续上次未完成的下载（architecture §4.5）。
    ref.watch(downloadManagerProvider);
    // WebDAV 自动同步（启动、回到前台、本地改动后），architecture §4.6。
    ref.watch(syncSchedulerProvider);
    return MaterialApp.router(
      title: 'Tsumugi',
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      routerConfig: ref.watch(routerProvider),
      scaffoldMessengerKey: ref.watch(rootMessengerKeyProvider),
      debugShowCheckedModeBanner: false,
    );
  }
}
