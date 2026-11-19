import 'downloads_view.dart';

export 'downloads_view.dart' show DownloadItemPage;

/// 下载页路由：`/downloads/:sourceId/:itemId`（各段 URL 编码）。
abstract final class DownloadRoutes {
  static const itemPattern = '/downloads/:sourceId/:itemId';

  static String item(String sourceId, String itemId) =>
      '/downloads/${Uri.encodeComponent(sourceId)}/${Uri.encodeComponent(itemId)}';
}

/// 由路由参数构造下载条目页。
DownloadItemPage downloadItemPage(Map<String, String> params) =>
    DownloadItemPage(sourceId: params['sourceId']!, itemId: params['itemId']!);
