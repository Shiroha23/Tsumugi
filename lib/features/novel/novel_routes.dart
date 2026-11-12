import 'package:go_router/go_router.dart';

import 'reader/novel_reader_page.dart';

/// 小说相关路由。`itemId` / `unitId` 往往本身就是 URL 路径，作为单个路径段时一律经过
/// [Uri.encodeComponent]；go_router 解析时会还原。
abstract final class NovelRoutes {
  /// go_router 路由模板。
  static const detailPattern = '/novel/:sourceId/:itemId';
  static const readerPattern = 'read/:unitId';

  /// 阅读器的完整路径模板（`?pos=N` 为章节内字符偏移，可省略）。
  static const readerPath = '/novel/:sourceId/:itemId/read/:unitId';

  static String detail(String sourceId, String itemId) =>
      '/novel/${Uri.encodeComponent(sourceId)}/${Uri.encodeComponent(itemId)}';

  static String reader(
    String sourceId,
    String itemId,
    String unitId, {
    int? position,
  }) {
    final path =
        '${detail(sourceId, itemId)}/read/${Uri.encodeComponent(unitId)}';
    return position == null || position <= 0 ? path : '$path?pos=$position';
  }
}

/// 由路由状态构造小说阅读器。
NovelReaderPage novelReaderPageFromState(GoRouterState state) =>
    NovelReaderPage(
      sourceId: state.pathParameters['sourceId']!,
      itemId: state.pathParameters['itemId']!,
      unitId: state.pathParameters['unitId']!,
      initialPosition:
          int.tryParse(state.uri.queryParameters['pos'] ?? '') ?? 0,
    );
