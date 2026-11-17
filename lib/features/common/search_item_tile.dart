import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../shared/image/source_image.dart';
import '../../sources/model/common.dart';
import '../comic/detail/comic_routes.dart';
import '../novel/novel_routes.dart';
import '../sources/labels.dart';
import '../video/video_routes.dart';

/// 按源的媒体类型打开列表条目的详情页（搜索结果与发现页共用）。
void openSearchItem(
  BuildContext context, {
  required String sourceId,
  required MediaType type,
  required SearchItem item,
}) {
  switch (type) {
    case MediaType.comic:
      context.push(ComicRoutes.detail(sourceId, item.id), extra: item);
    case MediaType.novel:
      context.push(NovelRoutes.detail(sourceId, item.id), extra: item);
    case MediaType.video:
      context.push(VideoRoutes.detail(sourceId, item.id), extra: item);
    case MediaType.music:
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('${type.label}详情页尚未实现')));
  }
}

/// 一个 [SearchItem] 的列表行：封面、标题、副标题与标签；点击进入详情。
class SearchItemTile extends StatelessWidget {
  const SearchItemTile({
    super.key,
    required this.sourceId,
    required this.item,
    required this.type,
  });

  final String sourceId;
  final SearchItem item;
  final MediaType type;

  @override
  Widget build(BuildContext context) {
    final subtitle = [
      ?item.subtitle,
      if (item.tags.isNotEmpty) item.tags.join(' · '),
    ].join('\n');
    return ListTile(
      leading: CoverImage(
        sourceId: sourceId,
        url: item.cover,
        headers: item.coverHeaders,
        width: 44,
        aspectRatio: 44 / 60,
      ),
      title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: subtitle.isEmpty
          ? null
          : Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
      onTap: () =>
          openSearchItem(context, sourceId: sourceId, type: type, item: item),
    );
  }
}
