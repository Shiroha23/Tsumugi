import 'dart:async';

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../shared/history/providers.dart';
import '../../../shared/library/library_item.dart';
import '../../../sources/model/common.dart';
import '../../../sources/model/content.dart';
import '../../../sources/runtime/source_runtime.dart';
import '../../../sources/source.dart';
import '../content/novel_document.dart';

part 'novel_reader_providers.g.dart';

/// 一章最多拼接的分页数（docs/source-spec.md §2.2.1）。
const maxNovelChapterPages = 100;

/// 阅读进度事件。[position] 为章节内字符偏移（§2.2.1），[length] 为章节总长度。
final class NovelReadingProgress {
  const NovelReadingProgress({
    required this.sourceId,
    required this.itemId,
    required this.unitId,
    required this.unitTitle,
    required this.position,
    required this.length,
    this.atEnd = false,
  });

  final String sourceId;
  final String itemId;
  final String unitId;

  /// 章节标题；章节列表尚未取得时为 null（取得后会以相同位置再报告一次）。
  final String? unitTitle;
  final int position;
  final int length;

  /// 已读到章节末尾（据此标记已读）。
  final bool atEnd;

  @override
  bool operator ==(Object other) =>
      other is NovelReadingProgress &&
      other.sourceId == sourceId &&
      other.itemId == itemId &&
      other.unitId == unitId &&
      other.unitTitle == unitTitle &&
      other.position == position &&
      other.length == length &&
      other.atEnd == atEnd;

  @override
  int get hashCode =>
      Object.hash(sourceId, itemId, unitId, unitTitle, position, length, atEnd);

  @override
  String toString() =>
      'NovelReadingProgress($sourceId, $itemId, $unitId "$unitTitle", '
      '$position/$length${atEnd ? ', end' : ''})';
}

typedef NovelProgressCallback = void Function(NovelReadingProgress progress);

/// 不自动重试：网络层已对连接错误 / 5xx 重试；界面提供手动“重试”。
Duration? _noRetry(int retryCount, Object error) => null;

/// 阅读进度的接收方：写入阅读进度与历史（节流，见 [NovelProgressRecorder]）。
@Riverpod(keepAlive: true)
NovelProgressCallback novelReaderProgressSink(Ref ref) {
  final recorder = NovelProgressRecorder(
    history: ref.watch(historyRepositoryProvider),
    itemFor: (p) {
      final d = ref.read(novelReaderDetailProvider(p.sourceId, p.itemId)).value;
      if (d == null) return null;
      return LibraryItem(
        sourceId: p.sourceId,
        itemId: p.itemId,
        title: d.title,
        mediaType: MediaType.novel,
        cover: d.cover,
      );
    },
  );
  ref.onDispose(recorder.flush);
  return recorder.report;
}

/// 节流写入阅读进度（与漫画的 `ComicProgressRecorder` 相同的策略）：
///
/// 按条目节流，距上次写入超过 [interval] 立即写，否则只保留最新一次，在间隔结束时写入
/// （页面关闭后仍会写入）。换章时先写入上一章的待写进度（已读标记依赖它）。
/// 章节标题未知时不写入，阅读器会在拿到章节列表后再报告一次。
class NovelProgressRecorder {
  NovelProgressRecorder({
    required this.history,
    required this.itemFor,
    this.interval = const Duration(seconds: 1),
  });

  final HistoryRepository history;
  final LibraryItem? Function(NovelReadingProgress progress) itemFor;
  final Duration interval;

  final _lastWrite = <(String, String), DateTime>{};
  final _pending = <(String, String), (NovelReadingProgress, LibraryItem)>{};
  final _timers = <(String, String), Timer>{};

  void report(NovelReadingProgress p) {
    if (p.unitTitle == null) return;
    final item = itemFor(p);
    if (item == null) return;
    final key = (p.sourceId, p.itemId);
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
    // 读到末尾的标记不能被随后（同一章内）的进度冲掉。
    if (_pending[key] case (final prev, _)
        when prev.unitId == p.unitId && prev.atEnd && !p.atEnd) {
      _write(key, prev, item);
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

  void _write((String, String) key, NovelReadingProgress p, LibraryItem item) {
    _lastWrite[key] = DateTime.now();
    history
        .recordProgress(
          item,
          unitId: p.unitId,
          unitTitle: p.unitTitle!,
          position: p.position,
          markRead: p.atEnd,
        )
        .ignore();
  }
}

/// 阅读器使用的源实例（与搜索 / 详情共享）。
@Riverpod(retry: _noRetry)
Future<Source> novelReaderSource(Ref ref, String sourceId) =>
    ref.watch(sourceInstanceProvider(sourceId).future);

/// 作品详情（章节列表），在阅读器打开期间缓存。
@Riverpod(retry: _noRetry)
Future<Detail> novelReaderDetail(
  Ref ref,
  String sourceId,
  String itemId,
) async {
  final source = await ref.watch(novelReaderSourceProvider(sourceId).future);
  return source.detail(itemId);
}

/// 一章的正文：取 `content(unitId)`，按 `nextPageId` 依次拉取章节内的后续分页并拼接（§2.2.1）。
@Riverpod(retry: _noRetry)
Future<NovelChapter> novelReaderChapter(
  Ref ref,
  String sourceId,
  String itemId,
  String unitId,
) async {
  final source = await ref.watch(novelReaderSourceProvider(sourceId).future);
  // 章节 id 集合：用来识别“下一页”其实是下一章。只订阅不依赖——详情重试时不重新拉取正文；
  // 详情失败时不做此判断。
  final detailProvider = novelReaderDetailProvider(sourceId, itemId);
  ref.listen(detailProvider, (_, _) {});
  final unitIds = ref
      .read(detailProvider.future)
      .then(
        (d) => {
          for (final u in d.units) u.id,
          for (final g in d.groups ?? const <UnitGroup>[])
            for (final u in g.units) u.id,
        },
        onError: (Object _) => const <String>{},
      );

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
    if (!ref.mounted) break;
    id = next;
  }
  return NovelChapter(blocks, imageHeaders: source.manifest.headers);
}
