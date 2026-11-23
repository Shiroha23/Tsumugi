import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../sources/model/common.dart';
import '../../core/network/network_exception.dart';
import '../../core/network/source_http_client.dart';
import '../../sources/model/content.dart';
import '../../sources/network_error_mapping.dart';
import '../../sources/runtime/source_runtime.dart';
import '../../sources/source.dart';
import '../export/export_models.dart' show ExportImage;
import '../export/novel_export_job.dart' show NovelExportJob;
import '../library/library_item.dart';
import '../novel/novel_chapter_loader.dart';
import '../novel/novel_document.dart';
import 'download_paths.dart';
import 'download_repository.dart';
import 'download_store.dart';
import 'novel_chapter_codec.dart';
import 'unit_manifest.dart';
import 'video_downloader.dart';

/// 由 sourceId 取得源实例（`SourceRuntime.get`，与阅读器同一缓存实例）。
typedef DownloadSourceResolver = Future<Source> Function(String sourceId);

/// 经 `SourceImageLoader.download`（不读写缓存，走该源的网络客户端）取图片字节。
typedef DownloadImageFetcher = Future<Uint8List> Function(
  String sourceId,
  ImageRef ref,
);

/// 为视频下载取得该源的客户端（与媒体代理相同：该源的 `SourceSession`）与清单的 `baseUrl`。
/// 调用方用完后 `close()` 客户端。
typedef DownloadVideoClientFactory = Future<(SourceHttpClient, Uri)> Function(
  String sourceId,
);

/// 文件读写失败。
const downloadIoError = 'E_IO';

/// 视频写入下载目录失败（磁盘满等，architecture §4.5.1）。
const downloadStorageError = 'E_STORAGE';

final class _Cancelled implements Exception {
  const _Cancelled();
}

class _Job {
  _Job(this.unit);

  final DownloadUnit unit;
  bool cancelled = false;

  /// 取消时中止进行中的请求（视频分片；漫画 / 小说仍在当前请求结束后停止）。
  final net = NetCancellation();

  /// 取消原因是删除：任务结束时再清一次目录（进行中的写入可能晚于删除完成）。
  bool deleted = false;
  final done = Completer<void>();

  void check() {
    if (cancelled) throw const _Cancelled();
  }
}

/// 下载队列（docs/architecture.md §4.5）。
///
/// - 一个全局队列，按加入顺序；同一源一次只下载一个 unit，不同源最多同时 [maxConcurrentUnits] 个。
/// - 续传以文件为粒度：继续 / 重试时重新取 `content()`，来源标识列表与 `unit.json` 完全一致才跳过已写完的文件，
///   否则丢弃该 unit 已下载的文件、从头下载。
/// - `E_CHALLENGE` / `E_LOGIN_REQUIRED` 与源不可用：该 unit 进入 `paused` 并记下错误码，整个源暂停
///   （[DownloadUnit.pausesSource]），直到 [resumeSource]（验证完成后由界面调用）。
/// - 其他失败（网络层已重试）：unit 进入 `failed`，可单独 [resume]。
/// - 应用退出时进行中的 unit 在下次 [start] 时回到 `queued`。
class DownloadManager {
  DownloadManager({
    required this.repository,
    required this.store,
    required this.sourceFor,
    required this.fetchImage,
    this.videoClientFor,
    this.videoLimits = const VideoDownloadLimits(),
    this.maxConcurrentUnits = 2,
    this.maxNovelImageBytes = NovelExportJob.defaultMaxImageBytes,
    this.maxNovelTotalImageBytes = NovelExportJob.defaultMaxTotalImageBytes,
    this.maxNovelImages = defaultMaxNovelImages,
    this.maxComicPages = defaultMaxComicPages,
    this.maxComicUnitBytes = defaultMaxComicUnitBytes,
    this.manifestWriteInterval = 10,
  });

  static const defaultMaxNovelImages = 500;
  static const defaultMaxComicPages = 2000;
  static const defaultMaxComicUnitBytes = 1024 * 1024 * 1024;

  final DownloadRepository repository;
  final DownloadStore store;
  final DownloadSourceResolver sourceFor;
  final DownloadImageFetcher fetchImage;

  /// 为 null 时不支持视频下载（视频 unit 以 `E_UNSUPPORTED` 失败）。
  final DownloadVideoClientFactory? videoClientFor;
  final VideoDownloadLimits videoLimits;
  final int maxConcurrentUnits;

  /// 小说正文图片的单张 / 合计上限，沿用导出的默认值；超过的保留占位，不算失败。
  final int maxNovelImageBytes;
  final int maxNovelTotalImageBytes;

  /// 一章小说最多下载的正文图片数；之后的图片保留占位、不再请求。
  final int maxNovelImages;

  /// 一章漫画的页数与合计字节上限（下载目录不是缓存，不会被淘汰）；超过时 unit 以 `E_LIMIT` 失败。
  final int maxComicPages;
  final int maxComicUnitBytes;

  /// 每写完多少个文件重写一次 `unit.json`（结束、取消前总会再写一次）。
  final int manifestWriteInterval;

  /// 进行中的任务，按 sourceId（同一源只有一个）。
  final _jobs = <String, _Job>{};
  bool _started = false;
  bool _starting = false;
  bool _disposed = false;

  /// 队列被挂起（iOS 后台宽限时间将到、Android 前台服务被系统停止）：不开始新任务，
  /// 进行中的已回到 `queued`。回到前台时 [resumeQueue]（architecture §4.5.1「后台下载」）。
  bool get suspended => _suspended;
  bool _suspended = false;
  Future<void>? _pumping;
  bool _pumpAgain = false;

  /// 进行中的任务都结束且没有可开始的任务时完成（测试用）。
  Future<void> get idle async {
    await _startup;
    while (true) {
      final pumping = _pumping;
      if (pumping != null) {
        await pumping;
        continue;
      }
      if (_jobs.isEmpty) return;
      await Future.wait([for (final j in _jobs.values.toList()) j.done.future]);
    }
  }

  /// 应用启动时调用一次：上次进行中的 unit 回到 `queued`，然后开始处理队列。
  Future<void> start() async {
    if (_starting) return _startup;
    _starting = true;
    final done = Completer<void>();
    _startup = done.future;
    try {
      await _startQueue();
    } finally {
      done.complete();
    }
  }

  Future<void>? _startup;

  Future<void> _startQueue() async {
    // 清理与重置完成之前不开始任何任务（_pump 检查 _started）：否则新任务的 `*.part` 会被清理删掉、
    // 刚认领的 unit 会被重置。
    await repository.resetRunning();
    await _cleanPartFiles();
    _started = true;
    _pump();
  }

  /// 保存条目快照并把 [units] 加入队列，返回实际加入的数量（已完成或已在队列中的不重复加入）。
  Future<int> enqueue(
    LibraryItem item,
    Detail detail,
    List<DownloadRequestUnit> units,
  ) async {
    final n = await repository.enqueue(item, detail, units);
    _pump();
    return n;
  }

  /// 暂停一个 unit：进行中的在当前请求结束后停止（结果丢弃），已写完的文件保留，继续时按来源标识续传。
  ///
  /// 先写状态再取消：与队列的 [DownloadRepository.claim] 之间不论谁先，任务的最终状态都不会覆盖暂停
  /// （任务结束时只在仍为 `running` 时写入结果）。
  Future<void> pause(DownloadUnit u) async {
    await repository.setStatus(
      u.sourceId,
      u.itemId,
      u.unitId,
      DownloadStatus.paused,
    );
    _cancel(u);
    _pump();
  }

  /// 继续 / 重试一个暂停或失败的 unit。该源因验证 / 源不可用而暂停时一并恢复整个源，
  /// 否则它会一直排队。
  Future<void> resume(DownloadUnit u) async {
    await repository.setStatus(
      u.sourceId,
      u.itemId,
      u.unitId,
      DownloadStatus.queued,
    );
    await _resumeSourceIfPaused(u.sourceId);
    _pump();
  }

  Future<void> _resumeSourceIfPaused(String sourceId) async {
    if ((await repository.allUnits()).any(
      (x) => x.sourceId == sourceId && x.pausesSource,
    )) {
      await repository.setSourceStatus(
        sourceId,
        from: {DownloadStatus.paused},
        to: DownloadStatus.queued,
        onlySourcePausing: true,
      );
    }
  }

  /// 恢复因验证 / 登录或源不可用而暂停的源（在验证页完成后调用）。
  Future<void> resumeSource(String sourceId) async {
    await repository.setSourceStatus(
      sourceId,
      from: {DownloadStatus.paused},
      to: DownloadStatus.queued,
      onlySourcePausing: true,
    );
    _pump();
  }

  /// 暂停全部未完成的 unit（后台下载通知中的「暂停全部」）。
  Future<void> pauseAll() async {
    for (final u in await repository.allUnits()) {
      if (u.status == DownloadStatus.queued ||
          u.status == DownloadStatus.running) {
        await repository.setStatus(
          u.sourceId,
          u.itemId,
          u.unitId,
          DownloadStatus.paused,
          // 快照之后已完成（done）或失败的不覆盖。
          onlyFrom: const {DownloadStatus.queued, DownloadStatus.running},
        );
        _cancel(u);
      }
    }
    _pump();
  }

  /// 挂起队列：进行中的任务中止并回到 `queued`（已写完的文件保留，继续时续传），不再开始新任务。
  /// 用于系统即将挂起应用（iOS 后台宽限时间到期前）或停止前台服务（Android 15 的 `dataSync` 时限）。
  Future<void> suspend() async {
    if (_suspended) return;
    _suspended = true;
    final running = [for (final j in _jobs.values) j];
    for (final j in running) {
      j
        ..cancelled = true
        ..net.cancel();
    }
    // 先取消再改状态：任务结束时只在仍为 running 时写入结果，改回 queued 后不会被覆盖为 failed。
    for (final j in running) {
      await repository.setStatus(
        j.unit.sourceId,
        j.unit.itemId,
        j.unit.unitId,
        DownloadStatus.queued,
        onlyFrom: const {DownloadStatus.running},
      );
    }
    // 不等进行中的请求结束（漫画 / 小说的当前请求不中断）：结果会被丢弃，状态已是 queued。
  }

  /// 取消 [suspend]，继续处理队列。
  void resumeQueue() {
    if (!_suspended) return;
    _suspended = false;
    _pump();
  }

  /// 暂停 / 继续一个条目的全部未完成 unit。
  Future<void> pauseItem(String sourceId, String itemId) async {
    for (final u in await _unitsOf(sourceId, itemId)) {
      if (u.status == DownloadStatus.queued ||
          u.status == DownloadStatus.running) {
        await repository.setStatus(
          sourceId,
          itemId,
          u.unitId,
          DownloadStatus.paused,
          // 快照之后已完成（done）或失败的不覆盖。
          onlyFrom: const {DownloadStatus.queued, DownloadStatus.running},
        );
        _cancel(u);
      }
    }
    _pump();
  }

  Future<void> resumeItem(String sourceId, String itemId) async {
    for (final u in await _unitsOf(sourceId, itemId)) {
      if (u.status == DownloadStatus.paused ||
          u.status == DownloadStatus.failed) {
        await repository.setStatus(
          sourceId,
          itemId,
          u.unitId,
          DownloadStatus.queued,
        );
      }
    }
    await _resumeSourceIfPaused(sourceId);
    _pump();
  }

  Future<List<DownloadUnit>> _unitsOf(String sourceId, String itemId) async => [
    for (final u in await repository.allUnits())
      if (u.sourceId == sourceId && u.itemId == itemId) u,
  ];

  /// 删除一个 unit 的记录与文件。
  Future<void> deleteUnit(DownloadUnit u) async {
    _cancel(u, deleted: true);
    await repository.deleteUnit(u.sourceId, u.itemId, u.unitId);
    await store.deleteUnit(u.sourceId, u.itemId, u.unitId);
    _pump();
  }

  Future<void> deleteItem(String sourceId, String itemId) async {
    _cancelWhere((j) => j.unit.sourceId == sourceId && j.unit.itemId == itemId);
    await repository.deleteItem(sourceId, itemId);
    await store.deleteItem(sourceId, itemId);
    _pump();
  }

  /// 删除某源的全部下载（删除源时用户选择一并删除）。
  Future<void> deleteSource(String sourceId) async {
    _cancelWhere((j) => j.unit.sourceId == sourceId);
    await repository.deleteSource(sourceId);
    await store.deleteSource(sourceId);
    _pump();
  }

  /// 清空全部下载。
  Future<void> deleteAll() async {
    _cancelWhere((_) => true);
    await repository.deleteAll();
    await store.deleteAll();
  }

  void _cancel(DownloadUnit u, {bool deleted = false}) {
    final job = _jobs[u.sourceId];
    if (job != null &&
        job.unit.itemId == u.itemId &&
        job.unit.unitId == u.unitId) {
      job
        ..cancelled = true
        ..deleted = job.deleted || deleted;
      job.net.cancel();
    }
  }

  void _cancelWhere(bool Function(_Job) test, {bool deleted = true}) {
    for (final j in _jobs.values) {
      if (test(j)) {
        j
          ..cancelled = true
          ..deleted = j.deleted || deleted;
        j.net.cancel();
      }
    }
  }

  void dispose() {
    _disposed = true;
    // 退出不是删除：保留已写完的文件，下次启动时续传；用户已删除的仍在任务结束时清理目录。
    _cancelWhere((_) => true, deleted: false);
  }

  // ---------------------------------------------------------------------------
  // 队列

  void _pump() {
    if (!_started || _disposed || _suspended) return;
    if (_pumping != null) {
      _pumpAgain = true;
      return;
    }
    _pumping = _fill().whenComplete(() {
      _pumping = null;
      if (_pumpAgain) {
        _pumpAgain = false;
        _pump();
      }
    });
  }

  Future<void> _fill() async {
    try {
      final all = await repository.allUnits();
      final pausedSources = {
        for (final u in all)
          if (u.pausesSource) u.sourceId,
      };
      for (final u in await repository.queued()) {
        if (_disposed || _suspended || _jobs.length >= maxConcurrentUnits) {
          break;
        }
        if (_jobs.containsKey(u.sourceId) ||
            pausedSources.contains(u.sourceId)) {
          continue;
        }
        if (!await repository.claim(u.sourceId, u.itemId, u.unitId)) continue;
        if (_suspended || _disposed) {
          // 认领期间被挂起 / 退出：suspend() 的快照里没有它，放回队列。
          await repository.setStatus(
            u.sourceId,
            u.itemId,
            u.unitId,
            DownloadStatus.queued,
            onlyFrom: const {DownloadStatus.running},
          );
          break;
        }
        final job = _jobs[u.sourceId] = _Job(u);
        unawaited(_run(job));
      }
    } on Object catch (e) {
      // 数据库已关闭（退出中）等。
      debugPrint('[download] pump failed: $e');
    }
  }

  Future<void> _run(_Job job) async {
    final u = job.unit;
    try {
      final (files, total, bytes) = await _download(job);
      job.check();
      // 只在仍为 running 时写入：期间被暂停 / 删除的不覆盖。
      await repository.setStatus(
        u.sourceId,
        u.itemId,
        u.unitId,
        DownloadStatus.done,
        completedFiles: files,
        totalFiles: total,
        bytes: bytes,
        onlyFrom: const {DownloadStatus.running},
      );
    } on Object catch (e) {
      if (!job.cancelled && !_disposed) {
        final (status, code) = _classify(e);
        debugPrint('[download] ${u.unitId}: $e');
        try {
          await repository.setStatus(
            u.sourceId,
            u.itemId,
            u.unitId,
            status,
            errorCode: code,
            onlyFrom: const {DownloadStatus.running},
          );
        } on Object {
          // 记录已被删除 / 数据库已关闭。
        }
      }
    } finally {
      try {
        if (job.deleted) {
          await store.deleteUnit(u.sourceId, u.itemId, u.unitId);
        }
      } on Object catch (e) {
        debugPrint('[download] cleanup failed: $e');
      } finally {
        if (identical(_jobs[u.sourceId], job)) _jobs.remove(u.sourceId);
        job.done.complete();
        _pump();
      }
    }
  }

  static (DownloadStatus, String) _classify(Object e) => switch (e) {
    SourceUnavailableException() => (
      DownloadStatus.paused,
      downloadSourceUnavailable,
    ),
    SourceException(:final code)
        when code == SourceErrorCode.challenge ||
            code == SourceErrorCode.loginRequired =>
      (DownloadStatus.paused, code.wire),
    SourceException(:final code) => (DownloadStatus.failed, code.wire),
    NetworkException() => _classify(e.toSourceException()),
    DownloadStorageException() => (DownloadStatus.failed, downloadStorageError),
    FileSystemException() => (DownloadStatus.failed, downloadIoError),
    _ => (DownloadStatus.failed, SourceErrorCode.parse.wire),
  };

  /// 下载一个 unit，返回（已写完的文件数、总文件数、字节数）。
  Future<(int, int, int)> _download(_Job job) async {
    final u = job.unit;
    final item = await repository.item(u.sourceId, u.itemId);
    if (item?.item.mediaType == MediaType.video) return _downloadVideo(job);
    final kind = switch (item?.item.mediaType) {
      MediaType.comic => DownloadKind.comic,
      MediaType.novel => DownloadKind.novel,
      _ => throw const SourceException(
        SourceErrorCode.unsupported,
        '只支持下载漫画、小说与视频',
      ),
    };
    final dir = await store.unitDir(u.sourceId, u.itemId, u.unitId);
    // 认领与登记任务之间被暂停 / 删除时，[pause] 找不到任务可取消：以数据库中的状态为准。
    Future<void> ensureRunning() async {
      job.check();
      final now = await repository.unit(u.sourceId, u.itemId, u.unitId);
      if (now?.status != DownloadStatus.running) {
        job.cancelled = true;
        throw const _Cancelled();
      }
    }

    await ensureRunning();
    final source = await sourceFor(u.sourceId);
    job.check();

    final List<ImageRef> refs;
    NovelChapter? chapter;
    if (kind == DownloadKind.comic) {
      final content = await source.content(u.unitId);
      if (content is! ComicContent) {
        throw const SourceException(SourceErrorCode.parse, '不是漫画内容');
      }
      refs = content.images;
      if (refs.length > maxComicPages) {
        throw SourceException(
          SourceErrorCode.limit,
          '一章超过 $maxComicPages 页，不下载',
        );
      }
    } else {
      final detail = item?.detail;
      chapter = await loadNovelChapter(
        source,
        u.unitId,
        unitIds: detail == null ? const <String>{} : novelUnitIdsOf(detail),
        shouldStop: () => job.cancelled,
      );
      // 正文图片：按首次出现顺序、同一地址只下载一次，headers 与阅读器相同。
      final urls = <String>{
        for (final b in chapter.blocks)
          if (b is NovelImage) b.url,
      };
      refs = [
        for (final url in urls)
          ImageRef(url: url, headers: chapter.imageHeaders),
      ];
    }
    job.check();

    final keys = [for (final r in refs) imageSourceKey(r.url, r.headers)];
    UnitManifest? manifest;
    try {
      manifest = await DownloadStore.readManifest(dir);
    } on FormatException {
      manifest = null;
    }
    if (manifest == null ||
        manifest.kind != kind ||
        !manifest.sameSources(keys)) {
      // 来源变化（换了图片、顺序或数量）或记录损坏：从头下载，避免新旧内容混在一起。
      await DownloadStore.clear(dir);
      manifest = UnitManifest(
        kind: kind,
        files: [for (final k in keys) DownloadFileEntry(k)],
      );
    } else {
      final done = DownloadStore.fileIn(dir, doneFileName);
      if (await done.exists()) await done.delete();
    }
    job.check();
    await DownloadStore.writeManifest(dir, manifest);

    final files = List.of(manifest.files);
    var bytes = 0;
    var completed = 0;
    Future<void> progress() => repository.setProgress(
      u.sourceId,
      u.itemId,
      u.unitId,
      completedFiles: completed,
      totalFiles: refs.length,
      bytes: bytes,
    );
    await progress();

    var sinceWrite = 0;
    Future<void> writeManifest() async {
      sinceWrite = 0;
      await DownloadStore.writeManifest(dir, manifest!.copyWith(files: files));
    }

    try {
      for (final (i, ref) in refs.indexed) {
        await ensureRunning();
        // 上次因超限跳过的小说图片：保留占位，不再请求。
        if (files[i].skipped) continue;
        if (files[i].file case final name?) {
          final f = DownloadStore.fileIn(dir, name);
          if (await f.exists()) {
            final len = await f.length();
            if (len > 0) {
              bytes += len;
              completed++;
              continue;
            }
          }
          files[i] = files[i].withFile(null);
        }
        if (kind == DownloadKind.novel &&
            (bytes >= maxNovelTotalImageBytes || i >= maxNovelImages)) {
          files[i] = files[i].asSkipped();
          sinceWrite++;
          continue;
        }
        final data = await fetchImage(u.sourceId, ref);
        job.check();
        if (kind == DownloadKind.novel &&
            (data.length > maxNovelImageBytes ||
                bytes + data.length > maxNovelTotalImageBytes)) {
          // 保留占位，与导出一致；记下跳过，续传时不再请求。
          files[i] = files[i].asSkipped();
          sinceWrite++;
          continue;
        }
        if (kind == DownloadKind.comic &&
            bytes + data.length > maxComicUnitBytes) {
          throw SourceException(SourceErrorCode.limit, '一章超过合计字节上限，不下载');
        }
        final ext = ExportImage.sniff(data)?.extension;
        if (ext == null || !downloadImageExtensions.contains(ext)) {
          throw const SourceException(SourceErrorCode.parse, '无法识别的图片格式');
        }
        final name = kind == DownloadKind.comic
            ? comicPageFileName(i, ext)
            : novelImageFileName(i, ext);
        await DownloadStore.writeBytes(dir, name, data);
        files[i] = files[i].withFile(name);
        if (++sinceWrite >= manifestWriteInterval) await writeManifest();
        bytes += data.length;
        completed++;
        await progress();
      }
    } catch (_) {
      // 失败前记下已写完的文件，重试时按来源标识续传。
      if (sinceWrite > 0) await writeManifest();
      rethrow;
    }
    job.check();

    var finalManifest = manifest.copyWith(files: files);
    if (chapter != null) {
      final text = NovelChapterCodec.encode(chapter);
      await DownloadStore.writeText(dir, chapterFileName, text);
      bytes += utf8.encode(text).length;
      finalManifest = finalManifest.copyWith(
        images: {for (final (i, ref) in refs.indexed) ref.url: ?files[i].file},
      );
    }
    job.check();
    await DownloadStore.writeManifest(dir, finalManifest);
    await DownloadStore.markDone(dir);
    return (completed, refs.length, bytes);
  }

  /// 下载一个视频剧集（architecture §4.5.1）。
  Future<(int, int, int)> _downloadVideo(_Job job) async {
    final u = job.unit;
    final dir = await store.unitDir(u.sourceId, u.itemId, u.unitId);
    Future<void> ensureRunning() async {
      job.check();
      final now = await repository.unit(u.sourceId, u.itemId, u.unitId);
      if (now?.status != DownloadStatus.running) {
        job.cancelled = true;
        throw const _Cancelled();
      }
    }

    await ensureRunning();
    final clientFor = videoClientFor;
    if (clientFor == null) {
      throw const SourceException(SourceErrorCode.unsupported, '不支持视频下载');
    }
    final source = await sourceFor(u.sourceId);
    job.check();
    final content = await source.content(u.unitId);
    if (content is! VideoContent) {
      throw const SourceException(SourceErrorCode.parse, '不是视频内容');
    }
    await ensureRunning();
    final done = DownloadStore.fileIn(dir, doneFileName);
    if (await done.exists()) await done.delete();
    final (client, baseUrl) = await clientFor(u.sourceId);
    try {
      final result = await VideoDownloadTask(
        client: client,
        baseUrl: baseUrl,
        content: content,
        preferredLabel: u.streamLabel,
        dir: dir,
        abort: job.net,
        limits: videoLimits,
        onProgress: (completed, total, bytes) => repository.setProgress(
          u.sourceId,
          u.itemId,
          u.unitId,
          completedFiles: completed,
          totalFiles: total,
          bytes: bytes,
        ),
      ).run();
      job.check();
      await DownloadStore.markDone(dir);
      return result;
      // 暂停 / 删除时进行中的请求被中止而抛出的错误由 [_run] 忽略（job.cancelled）。
    } finally {
      client.close();
    }
  }

  /// 删除下载目录中崩溃 / 强杀留下的临时文件（`*.part`，architecture §4.5.1「安全」）。
  /// 启动时、开始任何任务之前调用。
  Future<void> _cleanPartFiles() async {
    try {
      final root = await store.root();
      if (!await root.exists()) return;
      await for (final e in root.list(recursive: true, followLinks: false)) {
        if (e is File && e.path.endsWith(partSuffix)) {
          try {
            await e.delete();
          } on FileSystemException {
            // 正被占用：下次启动再试。
          }
        }
      }
    } on Object catch (e) {
      debugPrint('[download] clean *.part failed: $e');
    }
  }
}
