import 'package:flutter/widgets.dart';

import '../../../sources/model/common.dart';
import '../../common/detail/media_detail_page.dart';
import '../reader/reader_route.dart';

/// 漫画详情：通用详情页 + 漫画阅读器地址（从“上次读到”的章节继续时带上页码）。
class ComicDetailPage extends StatelessWidget {
  const ComicDetailPage({
    super.key,
    required this.sourceId,
    required this.itemId,
    this.preview,
  });

  final String sourceId;
  final String itemId;

  /// 从搜索结果进入时带上的条目，用于加载期间先显示标题，并提供封面 headers。
  final SearchItem? preview;

  @override
  Widget build(BuildContext context) => MediaDetailPage(
    sourceId: sourceId,
    itemId: itemId,
    preview: preview,
    mediaType: MediaType.comic,
    readerLocation: (unitId, resume) =>
        comicReaderLocation(sourceId, itemId, unitId, page: resume?.page),
    progressLabel: (p) =>
        '上次读到：${p.unitTitle}'
        '${p.page == null ? '' : ' 第 ${p.page! + 1} 页'}',
  );
}
