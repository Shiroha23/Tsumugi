import 'package:flutter/material.dart';

import '../../../shared/export/export_models.dart' show unitGroupsOf;
import '../../../sources/model/common.dart';
import '../../common/detail/media_detail_page.dart';
import '../export/novel_export_dialog.dart';
import '../novel_routes.dart';

/// 小说详情：通用详情页 + 小说阅读器地址（从“上次读到”的章节继续时带上字符偏移）+ “导出”。
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
    extraActions: (context, detail, coverHeaders) => [
      OutlinedButton.icon(
        icon: const Icon(Icons.file_download_outlined),
        label: const Text('导出'),
        onPressed: unitGroupsOf(detail).every((g) => g.units.isEmpty)
            ? null
            : () => showNovelExportDialog(
                context,
                sourceId: sourceId,
                itemId: itemId,
                detail: detail,
                coverHeaders: coverHeaders,
              ),
      ),
    ],
  );
}
