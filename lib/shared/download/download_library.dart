import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../sources/model/common.dart';
import '../../sources/source.dart';
import '../novel/novel_document.dart';
import 'download_paths.dart';
import 'download_repository.dart';
import 'download_store.dart';
import 'novel_chapter_codec.dart';
import 'unit_manifest.dart';
import 'video_manifest.dart';

/// 已下载的视频剧集（离线回放，architecture §4.5.1）。
final class DownloadedVideo {
  const DownloadedVideo({
    required this.dir,
    required this.manifest,
    required this.layout,
    required this.subtitles,
  });

  final Directory dir;
  final VideoManifest manifest;

  /// 本地会话的播放列表与文件（名称都由客户端生成，已确认文件存在）。
  final LocalVideoLayout layout;

  /// 文件仍在的外挂字幕。
  final List<(VideoSubtitleEntry, File)> subtitles;

  /// 已下载的清晰度。
  String get label => manifest.label;

  File fileOf(String name) => DownloadStore.fileIn(dir, name);
}

/// 阅读器的详情取不到时是否改用下载快照：验证 / 登录类错误照常抛出（界面需要显示「打开验证页」，
/// 也不能让旧快照掩盖新章节），其余（离线、源被删除 / 禁用等）回退。
bool useDetailSnapshotFor(Object error) =>
    !(error is SourceException &&
        (error.code == SourceErrorCode.challenge ||
            error.code == SourceErrorCode.loginRequired));

/// 阅读器读取已下载内容的入口（docs/architecture.md §4.5）。
///
/// 只有 `download_units.status == done` 且目录中有完成标记的 unit 才从本地读取；
/// `unit.json` / `chapter.json` 损坏或漫画页文件缺失时调用 [markBroken]（标为未下载、删除残留文件），
/// 返回 null，阅读器回退到网络。
class DownloadLibrary {
  DownloadLibrary({required this.repository, required this.store});

  final DownloadRepository repository;
  final DownloadStore store;

  /// 已下载漫画章节各页的本地文件（按页序）；未下载或已损坏时为 null。
  Future<List<File>?> comicPages(
    String sourceId,
    String itemId,
    String unitId,
  ) async {
    final dir = await _doneDir(sourceId, itemId, unitId);
    if (dir == null) return null;
    try {
      final manifest = await DownloadStore.readManifest(dir);
      if (manifest == null || manifest.kind != DownloadKind.comic) {
        throw const FormatException('unit.json 缺失');
      }
      final files = <File>[];
      for (final f in manifest.files) {
        final name = f.file;
        if (name == null) throw const FormatException('有未下载的页');
        final file = DownloadStore.fileIn(dir, name);
        if (!await file.exists()) throw FormatException('文件缺失：$name');
        files.add(file);
      }
      return files;
    } on Object catch (e) {
      await markBroken(sourceId, itemId, unitId, e);
      return null;
    }
  }

  /// 已下载的小说章节（[NovelChapter.localImages] 为图片的本地文件）；未下载或已损坏时为 null。
  ///
  /// 映射中缺失的图片文件不算损坏：阅读器为它显示占位，不发起网络请求。
  Future<NovelChapter?> novelChapter(
    String sourceId,
    String itemId,
    String unitId,
  ) async {
    final dir = await _doneDir(sourceId, itemId, unitId);
    if (dir == null) return null;
    try {
      final manifest = await DownloadStore.readManifest(dir);
      if (manifest == null || manifest.kind != DownloadKind.novel) {
        throw const FormatException('unit.json 缺失');
      }
      final chapterFile = DownloadStore.fileIn(dir, chapterFileName);
      final chapter = NovelChapterCodec.decode(
        await chapterFile.readAsString(),
      );
      final local = <String, String>{};
      for (final MapEntry(key: url, value: name) in manifest.images.entries) {
        final file = DownloadStore.fileIn(dir, name);
        if (await file.exists()) local[url] = file.path;
      }
      return NovelChapter(
        chapter.blocks,
        imageHeaders: chapter.imageHeaders,
        localImages: local,
      );
    } on Object catch (e) {
      await markBroken(sourceId, itemId, unitId, e);
      return null;
    }
  }

  /// 已下载的视频剧集；未下载或已损坏（`video.json` 无效、分片文件缺失）时为 null（已标为未下载）。
  Future<DownloadedVideo?> video(
    String sourceId,
    String itemId,
    String unitId,
  ) async {
    final dir = await _doneDir(sourceId, itemId, unitId);
    if (dir == null) return null;
    try {
      final f = DownloadStore.fileIn(dir, videoManifestFileName);
      if (!await f.exists()) throw const FormatException('video.json 缺失');
      final manifest = VideoManifest.decode(await f.readAsString());
      if (manifest.isHls && !manifest.complete) {
        throw const FormatException('有未下载的分片');
      }
      final layout = localVideoLayout(manifest);
      for (final name in layout.files.keys) {
        final file = DownloadStore.fileIn(dir, name);
        if (!await file.exists() || await file.length() == 0) {
          throw FormatException('文件缺失：$name');
        }
      }
      // 单文件：记录了长度时必须一致（截断但保留文件头的文件也能通过容器识别）。
      if (manifest.file?.length case final length?) {
        final actual = await DownloadStore.fileIn(dir, videoFileName).length();
        if (actual != length) {
          throw FormatException('文件长度不符：$actual / $length');
        }
      }
      final subtitles = <(VideoSubtitleEntry, File)>[];
      for (final s in manifest.subtitles) {
        final file = DownloadStore.fileIn(dir, s.file);
        if (await file.exists()) subtitles.add((s, file));
      }
      return DownloadedVideo(
        dir: dir,
        manifest: manifest,
        layout: layout,
        subtitles: subtitles,
      );
    } on Object catch (e) {
      await markBroken(sourceId, itemId, unitId, e);
      return null;
    }
  }

  /// 下载时的 `Detail` 快照（离线或源不可用时打开目录用）。
  Future<Detail?> detailSnapshot(String sourceId, String itemId) async =>
      (await repository.item(sourceId, itemId))?.detail;

  Future<Directory?> _doneDir(
    String sourceId,
    String itemId,
    String unitId,
  ) async {
    final u = await repository.unit(sourceId, itemId, unitId);
    if (u == null || u.status != DownloadStatus.done) return null;
    final dir = await store.unitDir(sourceId, itemId, unitId);
    if (!await DownloadStore.isDone(dir)) {
      await markBroken(sourceId, itemId, unitId, '缺少完成标记');
      return null;
    }
    return dir;
  }

  /// 本地文件缺失或损坏（含阅读器解码失败）：把 unit 标为未下载（`failed`，可重试）并删除残留文件。
  ///
  /// 只在仍为 `done` 时生效：迟到或重复的调用不会删掉用户已重新开始下载的目录。
  Future<void> markBroken(
    String sourceId,
    String itemId,
    String unitId, [
    Object? reason,
  ]) async {
    final changed = await repository.setStatus(
      sourceId,
      itemId,
      unitId,
      DownloadStatus.failed,
      errorCode: downloadFilesMissing,
      completedFiles: 0,
      bytes: 0,
      onlyFrom: const {DownloadStatus.done},
    );
    if (changed == 0) return;
    debugPrint('[download] $unitId 本地文件不可用，回退到网络：$reason');
    await store.deleteUnit(sourceId, itemId, unitId);
  }
}
