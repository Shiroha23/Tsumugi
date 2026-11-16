import 'dart:async';

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../shared/history/providers.dart';
import '../../../shared/library/providers.dart';
import '../../../sources/model/common.dart';

part 'video_progress.g.dart';

/// 播放进度事件。[item] 为写入历史的条目快照（见 [videoItemSnapshot]）。
final class VideoPlaybackProgress {
  const VideoPlaybackProgress({
    required this.item,
    required this.unitId,
    required this.unitTitle,
    required this.position,
    this.finished = false,
  });

  final LibraryItem item;
  final String unitId;
  final String unitTitle;
  final Duration position;

  /// 已看完（播放完成或到达片尾，见 `isFinished`）：标记已读，位置记为 0。
  final bool finished;

  @override
  String toString() =>
      'VideoPlaybackProgress(${item.sourceId}, ${item.itemId}, $unitId '
      '"$unitTitle", $position${finished ? ', finished' : ''})';
}

/// 节流写入播放进度（architecture §5.2「视频播放」）。
///
/// 按条目节流：距上次写入超过 [interval] 立即写，否则只保留最新一次，在间隔结束时写入
/// （页面关闭后仍会写入）。`immediate`（暂停、换集、离开页面）与第一次“看完”立即写入；
/// 换集时先写入上一集的待写进度。
class VideoProgressRecorder {
  VideoProgressRecorder({
    required this.history,
    this.interval = const Duration(seconds: 5),
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  final HistoryRepository history;
  final Duration interval;
  final DateTime Function() _now;

  final _lastWrite = <(String, String), DateTime>{};
  final _lastWritten = <(String, String), VideoPlaybackProgress>{};
  final _pending = <(String, String), VideoPlaybackProgress>{};
  final _timers = <(String, String), Timer>{};

  void report(VideoPlaybackProgress p, {bool immediate = false}) {
    final key = (p.item.sourceId, p.item.itemId);
    if (_pending[key] case final prev? when prev.unitId != p.unitId) {
      _cancel(key);
      _write(key, prev);
    }
    final written = _lastWritten[key];
    final newlyFinished =
        p.finished && !(written?.unitId == p.unitId && written!.finished);
    final last = _lastWrite[key];
    final now = _now();
    if (immediate ||
        newlyFinished ||
        last == null ||
        now.difference(last) >= interval) {
      _cancel(key);
      _write(key, p);
      return;
    }
    _pending[key] = p;
    _timers[key] ??= Timer(interval - now.difference(last), () {
      _timers.remove(key);
      if (_pending.remove(key) case final p?) _write(key, p);
    });
  }

  /// 立即写入所有待写的进度。
  void flush() {
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    for (final MapEntry(:key, value: p) in _pending.entries.toList()) {
      _write(key, p);
    }
    _pending.clear();
  }

  void _cancel((String, String) key) {
    _timers.remove(key)?.cancel();
    _pending.remove(key);
  }

  void _write((String, String) key, VideoPlaybackProgress p) {
    _lastWrite[key] = _now();
    _lastWritten[key] = p;
    history
        .recordProgress(
          p.item,
          unitId: p.unitId,
          unitTitle: p.unitTitle,
          position: p.finished ? 0 : p.position.inMilliseconds,
          markRead: p.finished,
        )
        .ignore();
  }
}

/// 播放页共用的进度写入器；应用退出（容器销毁）时写入待写的进度。
@Riverpod(keepAlive: true)
VideoProgressRecorder videoProgressRecorder(Ref ref) {
  final recorder = VideoProgressRecorder(
    history: ref.watch(historyRepositoryProvider),
  );
  ref.onDispose(recorder.flush);
  return recorder;
}

/// 写入历史的条目快照。
///
/// `Detail` 没有 `coverHeaders`（#24）：封面地址与书架条目或已有历史相同时沿用其中的 headers，
/// 否则回退到源清单的默认 headers（[sourceHeaders]，与详情页一致；为空时不带）。
Future<LibraryItem> videoItemSnapshot({
  required LibraryRepository library,
  required HistoryRepository history,
  required String sourceId,
  required String itemId,
  required Detail detail,
  required Headers sourceHeaders,
}) async {
  Headers? headersFrom(LibraryItem? known) =>
      known != null && known.cover == detail.cover && known.coverHeaders != null
      ? known.coverHeaders
      : null;

  final coverHeaders =
      headersFrom((await library.get(sourceId, itemId))?.item) ??
      headersFrom((await history.latestProgress(sourceId, itemId))?.item) ??
      (sourceHeaders.isEmpty ? null : sourceHeaders);
  return LibraryItem(
    sourceId: sourceId,
    itemId: itemId,
    title: detail.title,
    mediaType: MediaType.video,
    cover: detail.cover,
    coverHeaders: detail.cover == null ? null : coverHeaders,
  );
}
