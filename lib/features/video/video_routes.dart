import 'package:go_router/go_router.dart';

import 'player/video_player_page.dart';

/// 视频相关路由。`itemId` / `unitId` 往往本身就是 URL 路径，作为单个路径段时一律经过
/// [Uri.encodeComponent]；go_router 解析时会还原。
abstract final class VideoRoutes {
  /// go_router 路由模板。
  static const detailPattern = '/video/:sourceId/:itemId';
  static const playerPattern = 'play/:unitId';

  /// 播放页的完整路径模板（`?pos=<毫秒>` 为起始位置）。
  static const playerPath = '/video/:sourceId/:itemId/play/:unitId';

  static String detail(String sourceId, String itemId) =>
      '/video/${Uri.encodeComponent(sourceId)}/${Uri.encodeComponent(itemId)}';

  /// 播放页地址；[position] 为起始位置（毫秒），省略时使用该剧集记录的进度。
  static String player(
    String sourceId,
    String itemId,
    String unitId, {
    int? position,
  }) =>
      '${detail(sourceId, itemId)}/play/${Uri.encodeComponent(unitId)}'
      '${position != null && position > 0 ? '?pos=$position' : ''}';
}

/// 由路由状态构造播放页（`extra` 为剧集标题）。
VideoPlayerPage videoPlayerPageFromState(GoRouterState state) {
  final pos = int.tryParse(state.uri.queryParameters['pos'] ?? '');
  return VideoPlayerPage(
    sourceId: state.pathParameters['sourceId']!,
    itemId: state.pathParameters['itemId']!,
    unitId: state.pathParameters['unitId']!,
    title: state.extra is String ? state.extra! as String : null,
    start: pos != null && pos > 0 ? Duration(milliseconds: pos) : null,
  );
}
