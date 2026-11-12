import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../sources/model/common.dart';
import '../../../sources/model/content.dart';
import '../../../sources/registry/providers.dart';
import '../../../sources/script/script_source.dart';
import '../../../sources/source.dart';

part 'reader_providers.g.dart';

/// 阅读进度事件。页码从 0 开始；[pageCount] 为本章图片数。
final class ComicReadingProgress {
  const ComicReadingProgress({
    required this.sourceId,
    required this.itemId,
    required this.unitId,
    required this.unitTitle,
    required this.pageIndex,
    required this.pageCount,
  });

  final String sourceId;
  final String itemId;
  final String unitId;

  /// 章节标题；章节列表尚未取得时为 null（取得后会以相同页码再报告一次）。
  final String? unitTitle;
  final int pageIndex;
  final int pageCount;

  @override
  bool operator ==(Object other) =>
      other is ComicReadingProgress &&
      other.sourceId == sourceId &&
      other.itemId == itemId &&
      other.unitId == unitId &&
      other.unitTitle == unitTitle &&
      other.pageIndex == pageIndex &&
      other.pageCount == pageCount;

  @override
  int get hashCode =>
      Object.hash(sourceId, itemId, unitId, unitTitle, pageIndex, pageCount);

  @override
  String toString() =>
      'ComicReadingProgress($sourceId, $itemId, $unitId "$unitTitle", '
      '${pageIndex + 1}/$pageCount)';
}

/// 不自动重试：网络层已对连接错误 / 5xx 重试，其余错误（验证、白名单、解析）重试无益；
/// 界面提供手动“重试”。
Duration? _noRetry(int retryCount, Object error) => null;

typedef ComicProgressCallback = void Function(ComicReadingProgress progress);

/// 阅读进度的接收方。默认丢弃；书架 / 历史数据层在集成阶段覆盖此 provider。
///
/// 页码变化（含打开章节、切换章节）时立即调用，同一进度不重复报告；需要节流的话由接收方处理。
@Riverpod(keepAlive: true)
ComicProgressCallback comicReaderProgressSink(Ref ref) => (_) {};

/// 阅读器使用的可运行 [Source]：注册表中的清单 → 引擎工厂。页面关闭后释放。
///
/// 集成阶段如有全局的“按 id 取源”provider，可覆盖此 provider 复用同一实例。
@Riverpod(retry: _noRetry)
Future<Source> comicReaderSource(Ref ref, String sourceId) async {
  final installed = await ref.watch(sourceRegistryProvider).get(sourceId);
  final manifest = installed?.manifest;
  if (installed == null || manifest == null) {
    throw SourceException(
      SourceErrorCode.unsupported,
      installed == null ? '源未安装：$sourceId' : '源清单不可用：${installed.loadError}',
    );
  }
  final source = await ref.watch(sourceFactoriesProvider).create(manifest);
  ref.onDispose(() {
    if (source is ScriptSource) source.dispose();
  });
  return source;
}

/// 作品详情（用于章节列表），在阅读器打开期间缓存。
@Riverpod(retry: _noRetry)
Future<Detail> comicReaderDetail(
  Ref ref,
  String sourceId,
  String itemId,
) async {
  final source = await ref.watch(comicReaderSourceProvider(sourceId).future);
  return source.detail(itemId);
}

/// 章节内容（图片列表）。
@Riverpod(retry: _noRetry)
Future<ComicContent> comicReaderChapter(
  Ref ref,
  String sourceId,
  String unitId,
) async {
  final source = await ref.watch(comicReaderSourceProvider(sourceId).future);
  final content = await source.content(unitId);
  if (content is! ComicContent) {
    throw const SourceException(SourceErrorCode.parse, '不是漫画内容');
  }
  return content;
}

/// 详情中的章节（阅读顺序）：优先 `units`，为空时取第一组。
List<Unit> readingOrder(Detail detail) => detail.units.isNotEmpty
    ? detail.units
    : (detail.groups?.firstOrNull?.units ?? const []);
