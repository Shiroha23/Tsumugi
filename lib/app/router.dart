import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../features/comic/detail/comic_detail_page.dart';
import '../features/comic/detail/comic_routes.dart';
import '../features/comic/reader/reader_route.dart';
import '../features/library/library_page.dart';
import '../features/novel/detail/novel_detail_page.dart';
import '../features/novel/novel_routes.dart';
import '../features/search/search_page.dart';
import '../features/settings/settings_page.dart';
import '../features/sources/sources_page.dart';
import '../features/video/detail/video_detail_page.dart';
import '../features/video/video_routes.dart';
import '../shared/webview/providers.dart';
import '../sources/model/common.dart';
import 'shell.dart';

part 'router.g.dart';

abstract final class Routes {
  static const library = '/library';
  static const search = '/search';
  static const sources = '/sources';
  static const settings = '/settings';

  /// 漫画阅读器；地址用 `comicReaderLocation(...)` 生成。
  static const comicReader = comicReaderRoutePath;

  /// 小说阅读器；地址用 `NovelRoutes.reader(...)` 生成。
  static const novelReader = NovelRoutes.readerPath;
}

@Riverpod(keepAlive: true)
GoRouter router(Ref ref) {
  final router = GoRouter(
    navigatorKey: ref.watch(rootNavigatorKeyProvider),
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
          // 漫画阅读器：完整路径即 Routes.comicReader（`?page=N` 为初始页，从 0 开始）。
          GoRoute(
            path: ComicRoutes.readerPattern,
            builder: (_, state) => comicReaderPageFromState(state),
          ),
        ],
      ),
      // M3 小说：详情与阅读器（`?pos=N` 为章节内字符偏移）。
      GoRoute(
        path: NovelRoutes.detailPattern,
        builder: (_, state) => NovelDetailPage(
          sourceId: state.pathParameters['sourceId']!,
          itemId: state.pathParameters['itemId']!,
          preview: state.extra is SearchItem
              ? state.extra! as SearchItem
              : null,
        ),
        routes: [
          GoRoute(
            path: NovelRoutes.readerPattern,
            builder: (_, state) => novelReaderPageFromState(state),
          ),
        ],
      ),
      // M4 视频（技术验证）：详情与最小播放页。
      GoRoute(
        path: VideoRoutes.detailPattern,
        builder: (_, state) => VideoDetailPage(
          sourceId: state.pathParameters['sourceId']!,
          itemId: state.pathParameters['itemId']!,
          preview: state.extra is SearchItem
              ? state.extra! as SearchItem
              : null,
        ),
        routes: [
          GoRoute(
            path: VideoRoutes.playerPattern,
            builder: (_, state) => videoPlayerPageFromState(state),
          ),
        ],
      ),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
}
