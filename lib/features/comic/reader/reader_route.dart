import 'package:go_router/go_router.dart';

import 'comic_reader_page.dart';

/// 阅读器路由：`/comic/:sourceId/:itemId/read/:unitId?page=N`（N 从 0 开始，可省略）。
///
/// 作品 / 章节 id 通常是相对 URL（含 `/`、`?`），必须用 [comicReaderLocation] 生成地址，
/// 每段都会经 `Uri.encodeComponent` 编码；go_router 解析时会还原。
const comicReaderRoutePath = '/comic/:sourceId/:itemId/read/:unitId';

String comicReaderLocation(
  String sourceId,
  String itemId,
  String unitId, {
  int? page,
}) {
  final path =
      '/comic/${Uri.encodeComponent(sourceId)}/${Uri.encodeComponent(itemId)}'
      '/read/${Uri.encodeComponent(unitId)}';
  return page == null || page <= 0 ? path : '$path?page=$page';
}

/// 由路由状态构造阅读器页面。
ComicReaderPage comicReaderPageFromState(GoRouterState state) =>
    ComicReaderPage(
      sourceId: state.pathParameters['sourceId']!,
      itemId: state.pathParameters['itemId']!,
      unitId: state.pathParameters['unitId']!,
      initialPage: int.tryParse(state.uri.queryParameters['page'] ?? '') ?? 0,
    );
