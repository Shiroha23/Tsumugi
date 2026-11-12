/// 漫画相关路由的路径。`itemId` / `unitId` 往往本身就是 URL 路径（如 `/comic/book/1`），
/// 因此作为单个路径段时一律经过 [Uri.encodeComponent]。
abstract final class ComicRoutes {
  /// go_router 路由模板。
  static const detailPattern = '/comic/:sourceId/:itemId';
  static const readerPattern = 'read/:unitId';

  static String detail(String sourceId, String itemId) =>
      '/comic/${Uri.encodeComponent(sourceId)}/${Uri.encodeComponent(itemId)}';

  static String reader(String sourceId, String itemId, String unitId) =>
      '${detail(sourceId, itemId)}/read/${Uri.encodeComponent(unitId)}';
}
