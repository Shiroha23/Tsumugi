import 'package:flutter/widgets.dart';

import '../../../sources/model/common.dart';
import '../../common/detail/media_detail_page.dart';
import '../novel_routes.dart';

/// 小说详情：通用详情页 + 小说阅读器地址（从“上次读到”的章节继续时带上字符偏移）。
class NovelDetailPage extends StatelessWidget {
  const NovelDetailPage({
    super.key,
    required this.sourceId,
    required this.itemId,
    this.preview,
  });

  final String sourceId;
  final String itemId;
  final SearchItem? preview;

  @override
  Widget build(BuildContext context) => MediaDetailPage(
    sourceId: sourceId,
    itemId: itemId,
    preview: preview,
    mediaType: MediaType.novel,
    readerLocation: (unitId, resume) => NovelRoutes.reader(
      sourceId,
      itemId,
      unitId,
      position: resume?.position,
    ),
    progressLabel: (p) => '上次读到：${p.unitTitle}',
  );
}
