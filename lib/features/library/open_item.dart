import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../shared/history/providers.dart';
import '../../shared/library/providers.dart';
import '../../sources/model/common.dart';
import '../comic/detail/comic_routes.dart';
import '../comic/reader/reader_route.dart';
import '../novel/novel_routes.dart';
import '../sources/labels.dart';

/// 打开一个书架 / 历史条目。[progress] 从历史打开时为该条目的最新进度，
/// 可用来直接跳到阅读器继续阅读；从书架打开时为 null。
typedef OpenLibraryItem = void Function(
  BuildContext context,
  LibraryItem item, {
  ItemProgress? progress,
});

/// 书架页点击条目时的跳转（测试中可覆盖）；为 null 时书架页提示“暂不可用”。
///
/// - 从书架打开：进入详情页。
/// - 从历史打开（带进度）：直接进入阅读器，从记录的章节与页码（小说为字符偏移）继续。
/// - 尚未实现的媒体类型：提示。
final openItemProvider = Provider<OpenLibraryItem?>((ref) => openLibraryItem);

void openLibraryItem(
  BuildContext context,
  LibraryItem item, {
  ItemProgress? progress,
}) {
  switch (item.mediaType) {
    case MediaType.comic:
      context.push(
        progress == null
            ? ComicRoutes.detail(item.sourceId, item.itemId)
            : comicReaderLocation(
                item.sourceId,
                item.itemId,
                progress.unitId,
                page: progress.page,
              ),
      );
    case MediaType.novel:
      context.push(
        progress == null
            ? NovelRoutes.detail(item.sourceId, item.itemId)
            : NovelRoutes.reader(
                item.sourceId,
                item.itemId,
                progress.unitId,
                position: progress.position,
              ),
      );
    case MediaType.video || MediaType.music:
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('${item.mediaType.label}尚未支持')));
  }
}
