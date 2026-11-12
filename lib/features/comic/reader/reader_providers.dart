import 'dart:async';

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../shared/history/providers.dart';
import '../../../shared/library/library_item.dart';
import '../../../sources/model/common.dart';
import '../../../sources/model/content.dart';
import '../../../sources/runtime/source_runtime.dart';
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

/// 阅读进度的接收方：写入阅读进度与历史（`HistoryRepository`）。
///
/// 页码变化（含打开章节、切换章节）时立即调用，同一进度不重复报告。这里按条目节流：
/// 距上次写入超过 [ComicProgressRecorder.interval] 立即写，否则只保留最新一次，在间隔结束时写入
/// （页面关闭后仍会写入，不会丢掉最后一页）。章节标题未知时（详情尚未加载）不写入，
/// 阅读器会在拿到章节列表后以相同页码再报告一次。
@Riverpod(keepAlive: true)
ComicProgressCallback comicReaderProgressSink(Ref ref) {
  final recorder = ComicProgressRecorder(
    history: ref.watch(historyRepositoryProvider),
    itemFor: (p) {
      final detail = ref.read(comicReaderDetailProvider(p.sourceId, p.itemId));
      final d = detail.value;
      if (d == null) return null;
      return LibraryItem(
        sourceId: p.sourceId,
        itemId: p.itemId,
        title: d.title,
        mediaType: MediaType.comic,
        cover: d.cover,
      );
    },
  );
  ref.onDispose(recorder.flush);
  return recorder.report;
}

/// [comicReaderProgressSink] 的实现，单独成类便于测试。
class ComicProgressRecorder {
  ComicProgressRecorder({
    required this.history,
    required this.itemFor,
    this.interval = const Duration(seconds: 1),
  });

  final HistoryRepository history;

  /// 由进度事件得到条目快照（标题 / 封面）；返回 null 时本次不写入。
  final LibraryItem? Function(ComicReadingProgress progress) itemFor;
  final Duration interval;

  final _lastWrite = <(String, String), DateTime>{};
  final _pending = <(String, String), (ComicReadingProgress, LibraryItem)>{};
  final _timers = <(String, String), Timer>{};

  void report(ComicReadingProgress p) {
    final title = p.unitTitle;
    if (title == null) return;
    final item = itemFor(p);
    if (item == null) return;
    final key = (p.sourceId, p.itemId);
    // 换章时先写入上一章的待写进度：已读标记依赖它的最后一页，不能被下一章覆盖。
    if (_pending[key] case (final prev, final prevItem)
        when prev.unitId != p.unitId) {
      _timers.remove(key)?.cancel();
      _pending.remove(key);
      _write(key, prev, prevItem);
    }
    final last = _lastWrite[key];
    final now = DateTime.now();
    if (last == null || now.difference(last) >= interval) {
      _timers.remove(key)?.cancel();
      _pending.remove(key);
      _write(key, p, item);
      return;
    }
    _pending[key] = (p, item);
    _timers[key] ??= Timer(interval - now.difference(last), () {
      _timers.remove(key);
      if (_pending.remove(key) case (final p, final item)) _write(key, p, item);
    });
  }

  /// 立即写入所有待写的进度。
  void flush() {
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    for (final MapEntry(:key, value: (p, item)) in _pending.entries.toList()) {
      _write(key, p, item);
    }
    _pending.clear();
  }

  void _write((String, String) key, ComicReadingProgress p, LibraryItem item) {
    _lastWrite[key] = DateTime.now();
    history
        .recordProgress(
          item,
          unitId: p.unitId,
          unitTitle: p.unitTitle!,
          page: p.pageIndex,
          pageCount: p.pageCount,
        )
        .ignore();
  }
}

/// 阅读器使用的可运行 [Source]：复用全局的源实例（`sourceInstanceProvider`），
/// 与搜索 / 详情共享同一个实例与脚本 worker；源被禁用 / 删除 / 升级时自动失效。
@Riverpod(retry: _noRetry)
Future<Source> comicReaderSource(Ref ref, String sourceId) =>
    ref.watch(sourceInstanceProvider(sourceId).future);

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

/// 详情中的章节（阅读顺序）。
///
/// 给出 [unitId] 时返回**包含该章节**的那一组（先查 `units`，再依次查各线路），
/// 这样从非首条线路打开的章节也能取到标题、上一章 / 下一章。
/// 没有给出或都不包含时：优先 `units`，为空时取第一组。
List<Unit> readingOrder(Detail detail, [String? unitId]) {
  if (unitId != null) {
    bool has(List<Unit> units) => units.any((u) => u.id == unitId);
    if (has(detail.units)) return detail.units;
    for (final g in detail.groups ?? const <UnitGroup>[]) {
      if (has(g.units)) return g.units;
    }
  }
  return detail.units.isNotEmpty
      ? detail.units
      : (detail.groups?.firstOrNull?.units ?? const []);
}
