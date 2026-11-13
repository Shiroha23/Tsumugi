import 'dart:async';

import '../../sources/model/common.dart';
import '../../sources/model/content.dart';
import '../../sources/source.dart';
import 'novel_document.dart';

/// 一章最多拼接的分页数（docs/source-spec.md §2.2.1）。
const maxNovelChapterPages = 100;

/// 详情中全部章节的 id（含各线路），用来识别“下一页”其实是下一章。
Set<String> novelUnitIdsOf(Detail detail) => {
  for (final u in detail.units) u.id,
  for (final g in detail.groups ?? const <UnitGroup>[])
    for (final u in g.units) u.id,
};

/// 读取一章正文：取 `content(unitId)`，按 `nextPageId` 依次拉取章节内的后续分页并拼接（§2.2.1）。
///
/// 阅读器（`novelReaderChapterProvider`）与导出（`shared/export`）共用此逻辑。
/// 分页按顺序逐个请求，因此遵守源的限速与白名单（都由 [source] 的网络层负责）。
///
/// 停止条件：`nextPageId` 为空、与已取过的页重复、属于 [unitIds]（下一章），或已取满
/// [maxNovelChapterPages] 页。[unitIds] 取不到（详情失败）时不做“下一章”判断。
/// [shouldStop] 在每次请求下一页之前检查，返回 true 时直接返回已拼接的部分。
Future<NovelChapter> loadNovelChapter(
  Source source,
  String unitId, {
  FutureOr<Set<String>> unitIds = const <String>{},
  bool Function()? shouldStop,
}) async {
  final baseUrl = source.manifest.baseUrl;
  final blocks = <NovelBlock>[];
  final seen = {unitId};
  var id = unitId;
  for (var page = 0; page < maxNovelChapterPages; page++) {
    final content = await source.content(id);
    if (content is! NovelContent) {
      throw const SourceException(SourceErrorCode.parse, '不是小说内容');
    }
    blocks.addAll(novelBlocksFromContent(content, baseUrl: baseUrl));
    final next = content.nextPageId?.trim();
    if (next == null || next.isEmpty || !seen.add(next)) break;
    if ((await unitIds).contains(next)) break;
    if (shouldStop?.call() ?? false) break;
    id = next;
  }
  return NovelChapter(blocks, imageHeaders: source.manifest.headers);
}
