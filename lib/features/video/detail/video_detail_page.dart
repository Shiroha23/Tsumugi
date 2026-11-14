import 'package:flutter/material.dart';

import '../../../sources/model/common.dart';
import '../../common/detail/media_detail_page.dart';
import '../video_routes.dart';

/// 视频详情：通用详情页 + 播放页地址。
///
/// M4 技术验证阶段只有最小播放页，尚未记录播放进度（“上次看到”暂不出现）。
class VideoDetailPage extends StatelessWidget {
  const VideoDetailPage({
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
    mediaType: MediaType.video,
    readerLocation: (unitId, _) => VideoRoutes.player(sourceId, itemId, unitId),
    progressLabel: (p) => '上次看到：${p.unitTitle}',
  );
}
