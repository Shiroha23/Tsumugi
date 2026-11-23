import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../core/storage/app_database.dart';
import '../../sources/registry/providers.dart';
import '../../sources/runtime/source_runtime.dart';
import '../image/image_providers.dart';
import '../video/media_proxy_providers.dart';
import 'download_library.dart';
import 'download_manager.dart';
import 'download_repository.dart';
import 'download_store.dart';

export 'download_library.dart';
export 'download_manager.dart';
export 'download_repository.dart';
export 'download_store.dart';
export 'video_downloader.dart'
    show DownloadStorageException, VideoDownloadLimits;
export 'video_manifest.dart';

part 'providers.g.dart';

/// 下载目录：应用支持目录下的 `downloads/`（系统不会当作缓存清理，architecture §4.5）。
@Riverpod(keepAlive: true)
DownloadStore downloadStore(Ref ref) => DownloadStore(
  () async => Directory(
    '${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}downloads',
  ),
);

@Riverpod(keepAlive: true)
DownloadRepository downloadRepository(Ref ref) =>
    DownloadRepository(ref.watch(appDatabaseProvider));

/// 全局下载队列。创建时即开始处理上次未完成的队列（`TsumugiApp` 启动时读取一次）。
@Riverpod(keepAlive: true)
DownloadManager downloadManager(Ref ref) {
  final runtime = ref.watch(sourceRuntimeProvider);
  final images = ref.watch(sourceImageLoaderProvider);
  final manager = DownloadManager(
    repository: ref.watch(downloadRepositoryProvider),
    store: ref.watch(downloadStoreProvider),
    sourceFor: runtime.get,
    fetchImage: images.download,
    // 与媒体代理相同：为该源新建使用其 SourceSession（Cookie、UA、令牌桶）的客户端（architecture §4.5.1）。
    videoClientFor: (sourceId) async {
      final manifest = (await ref.read(sourceRegistryProvider).get(sourceId))
          ?.manifest;
      if (manifest == null) {
        throw SourceUnavailableException(sourceId, '源未安装或清单不可用');
      }
      return (
        ref.read(mediaProxyClientProvider)(manifest),
        Uri.parse(manifest.baseUrl),
      );
    },
  );
  ref.onDispose(manager.dispose);
  manager.start().ignore();
  return manager;
}

@Riverpod(keepAlive: true)
DownloadLibrary downloadLibrary(Ref ref) => DownloadLibrary(
  repository: ref.watch(downloadRepositoryProvider),
  store: ref.watch(downloadStoreProvider),
);

@riverpod
Stream<List<DownloadItem>> downloadItems(Ref ref) =>
    ref.watch(downloadRepositoryProvider).watchItems();

@riverpod
Stream<DownloadItem?> downloadItem(Ref ref, String sourceId, String itemId) =>
    ref.watch(downloadRepositoryProvider).watchItem(sourceId, itemId);

/// 某条目的下载 unit（详情页章节列表的“已下载”标记、下载页的章节状态）。
@riverpod
Stream<List<DownloadUnit>> downloadUnits(
  Ref ref,
  String sourceId,
  String itemId,
) => ref.watch(downloadRepositoryProvider).watchUnits(sourceId, itemId);

@riverpod
Stream<List<DownloadUnit>> allDownloadUnits(Ref ref) =>
    ref.watch(downloadRepositoryProvider).watchAllUnits();

/// 下载目录的总占用（字节）。
@riverpod
Future<int> downloadTotalBytes(Ref ref) =>
    ref.watch(downloadStoreProvider).totalBytes();
