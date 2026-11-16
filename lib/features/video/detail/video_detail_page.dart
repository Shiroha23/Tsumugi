import 'package:flutter/material.dart';

import '../../../sources/model/common.dart';
import '../../common/detail/media_detail_page.dart';
import '../player/video_playlist.dart' show formatPlaybackPosition;
import '../video_routes.dart';

/// 视频详情：通用详情页 + 播放页地址（从“上次看到”的剧集继续时带上位置）。
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
    readerLocation: (unitId, resume) => VideoRoutes.player(
      sourceId,
      itemId,
      unitId,
      position: resume?.position,
    ),
    progressLabel: (p) => switch (p.position) {
      final ms? when ms > 0 =>
        '上次看到：${p.unitTitle} '
            '${formatPlaybackPosition(Duration(milliseconds: ms))}',
      _ => '上次看到：${p.unitTitle}',
    },
  );
}
