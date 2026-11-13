import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../sources/model/content.dart';
import '../../sources/runtime/source_runtime.dart';
import '../image/image_providers.dart';
import 'export_saver.dart';
import 'novel_export_job.dart';

export 'export_models.dart';
export 'export_saver.dart';
export 'novel_export_job.dart';

part 'providers.g.dart';

/// 创建导出任务：源实例来自 `SourceRuntime`（即 `sourceInstanceProvider` 背后的同一缓存实例），
/// 封面经统一图片加载器（`sourceImageLoaderProvider`）取得。
class NovelExporter {
  const NovelExporter({
    required this.sourceFor,
    this.loadCover,
    this.buildInIsolate = true,
  });

  final ExportSourceResolver sourceFor;
  final ExportCoverLoader? loadCover;
  final bool buildInIsolate;

  NovelExportJob create(NovelExportRequest request) => NovelExportJob(
    request: request,
    sourceFor: sourceFor,
    loadCover: loadCover,
    buildInIsolate: buildInIsolate,
  );
}

@riverpod
NovelExporter novelExporter(Ref ref) {
  final runtime = ref.watch(sourceRuntimeProvider);
  final images = ref.watch(sourceImageLoaderProvider);
  return NovelExporter(
    sourceFor: runtime.get,
    loadCover: (sourceId, url, headers) =>
        images.load(sourceId, ImageRef(url: url, headers: headers)),
  );
}

@riverpod
ExportSaver exportSaver(Ref ref) => const FilePickerExportSaver();
