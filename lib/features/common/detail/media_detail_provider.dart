import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../sources/model/common.dart';
import '../../../sources/runtime/source_runtime.dart';

part 'media_detail_provider.g.dart';

/// 详情页数据：[detail] 与加载封面时要带的 headers。
final class MediaDetailData {
  const MediaDetailData({required this.detail, required this.sourceHeaders});

  final Detail detail;

  /// 源清单的默认 headers（`Detail` 没有 `coverHeaders`，封面回退使用它，
  /// 与声明式引擎给搜索结果封面附带的 headers 一致）。
  final Headers sourceHeaders;
}

@riverpod
Future<MediaDetailData> mediaDetail(
  Ref ref,
  String sourceId,
  String itemId,
) async {
  final source = await ref.watch(sourceInstanceProvider(sourceId).future);
  final detail = await source.detail(itemId);
  return MediaDetailData(
    detail: detail,
    sourceHeaders: source.manifest.headers,
  );
}
