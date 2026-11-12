import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../features/comic/detail/comic_detail_page.dart';
import '../features/comic/detail/comic_routes.dart';
import '../features/library/library_page.dart';
import '../features/search/search_page.dart';
import '../features/settings/settings_page.dart';
import '../features/sources/sources_page.dart';
import '../sources/model/common.dart';
import 'shell.dart';

part 'router.g.dart';

abstract final class Routes {
  static const library = '/library';
  static const search = '/search';
  static const sources = '/sources';
  static const settings = '/settings';
}

@Riverpod(keepAlive: true)
GoRouter router(Ref ref) {
  final router = GoRouter(
    initialLocation: Routes.library,
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => AppShell(shell: shell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: Routes.library,
                builder: (_, _) => const LibraryPage(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: Routes.search,
                builder: (_, _) => const SearchPage(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: Routes.sources,
                builder: (_, _) => const SourcesPage(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: Routes.settings,
                builder: (_, _) => const SettingsPage(),
              ),
            ],
          ),
        ],
      ),
      // M2 漫画：详情（搜索 / 详情会话）。itemId、unitId 经 URL 编码，见 ComicRoutes。
      GoRoute(
        path: ComicRoutes.detailPattern,
        builder: (_, state) => ComicDetailPage(
          sourceId: state.pathParameters['sourceId']!,
          itemId: state.pathParameters['itemId']!,
          preview: state.extra is SearchItem
              ? state.extra! as SearchItem
              : null,
        ),
        routes: [
          // 占位：由漫画阅读器会话替换为真正的阅读器页面。
          GoRoute(
            path: ComicRoutes.readerPattern,
            builder: (_, state) =>
                _ReaderPlaceholderPage(unitId: state.pathParameters['unitId']!),
          ),
        ],
      ),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
}

/// 阅读器占位页（漫画阅读器会话会替换）。
class _ReaderPlaceholderPage extends StatelessWidget {
  const _ReaderPlaceholderPage({required this.unitId});

  final String unitId;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('阅读')),
    body: Center(child: Text('阅读器尚未实现\n$unitId', textAlign: TextAlign.center)),
  );
}
