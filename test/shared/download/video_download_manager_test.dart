import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/storage/app_database.dart';
import 'package:tsumugi/shared/download/providers.dart';
import 'package:tsumugi/shared/library/library_item.dart';
import 'package:tsumugi/sources/model/common.dart';
import 'package:tsumugi/sources/model/content.dart';
import 'package:tsumugi/sources/model/manifest.dart';

import '../../core/network/mock_support.dart';
import '../../core/storage/test_database.dart';
import '../../sources/runtime/runtime_support.dart';

const _source = 'com.example.video';
const _item = '/video/show/9';

/// 下载队列中的视频剧集（architecture §4.5.1）：与漫画 / 小说共用队列，`video.json` + 完成标记，
/// 离线读取（[DownloadLibrary.video]），写入失败 → `E_STORAGE`，启动时清理 `*.part`。
void main() {
  late MockServer server;
  late Directory root;
  late AppDatabase db;
  late DownloadRepository repo;
  late DownloadStore store;
  late DownloadLibrary library;
  late DownloadManager manager;

  /// unitId → 内容。
  final contents = <String, VideoContent>{};

  setUpAll(() async => server = await MockServer.start());
  tearDownAll(() => server.close());

  DownloadManager newManager() => DownloadManager(
    repository: repo,
    store: store,
    sourceFor: (id) async => FakeSource(
      SourceManifest.fromJson(
        jsonDecode(fakeManifestJson(id, type: MediaType.video))
            as Map<String, dynamic>,
      ),
      onContent: (unitId) async => contents[unitId]!,
    ),
    fetchImage: (_, _) => throw UnimplementedError(),
    videoClientFor: (id) async => (
      mockClient(
        server,
        sourceId: id,
        baseUrl: 'http://video.example.com',
        allowedHosts: const [],
      ),
      Uri.parse('http://video.example.com'),
    ),
    videoLimits: const VideoDownloadLimits(progressInterval: Duration.zero),
  );

  setUp(() async {
    final tmp = await Directory.systemTemp.createTemp('tsumugi_vdl_');
    root = Directory('${tmp.path}${Platform.pathSeparator}downloads');
    db = openTestDatabase();
    repo = DownloadRepository(db);
    store = DownloadStore(() => root);
    library = DownloadLibrary(repository: repo, store: store);
    manager = newManager();
    contents
      ..clear()
      ..addAll({
        'ep1': const VideoContent(
          streams: [
            StreamRef(
              url: '/video/media/hls/master_sub.m3u8',
              type: StreamType.hls,
              quality: '720p',
            ),
            StreamRef(url: '/video/media/clip.mp4', quality: '360p'),
          ],
          subtitles: [
            SubtitleRef(url: '/video/media/subs/en.vtt', lang: 'English'),
          ],
        ),
        'ep2': const VideoContent(
          streams: [StreamRef(url: '/video/media/hls/live.m3u8')],
        ),
      });
  });

  tearDown(() async {
    manager.dispose();
    await manager.idle;
    await db.close();
    await root.parent.delete(recursive: true);
  });

  Future<void> enqueue(List<String> units, {String? label}) => manager.enqueue(
    const LibraryItem(
      sourceId: _source,
      itemId: _item,
      title: '虚构剧集',
      mediaType: MediaType.video,
    ),
    Detail(
      id: _item,
      title: '虚构剧集',
      units: [for (final u in units) Unit(id: u, title: u)],
    ),
    [
      for (final (i, u) in units.indexed)
        DownloadRequestUnit(
          Unit(id: u, title: u),
          groupName: '默认',
          index: i,
          streamLabel: label,
        ),
    ],
  );

  test(
    'downloads, then reads back offline through DownloadLibrary.video',
    () async {
      await manager.start();
      await enqueue(['ep1', 'ep2']);
      await manager.idle;
      final ep1 = (await repo.unit(_source, _item, 'ep1'))!;
      expect(ep1.status, DownloadStatus.done);
      expect(ep1.streamLabel, isNull);
      expect(ep1.completedFiles, 6);
      final ep2 = (await repo.unit(_source, _item, 'ep2'))!;
      expect(ep2.status, DownloadStatus.failed);
      expect(ep2.errorCode, 'E_UNSUPPORTED');

      final video = (await library.video(_source, _item, 'ep1'))!;
      expect(video.label, '720p');
      expect(video.layout.root, 'index.m3u8');
      expect(video.subtitles.single.$1.lang, 'English');
      expect(await library.video(_source, _item, 'ep2'), isNull);
    },
  );

  test('chosen quality is stored and used', () async {
    await manager.start();
    await enqueue(['ep1'], label: '360p');
    await manager.idle;
    expect((await repo.unit(_source, _item, 'ep1'))!.streamLabel, '360p');
    final video = (await library.video(_source, _item, 'ep1'))!;
    expect(video.manifest.isHls, isFalse);
    expect(video.layout.root, videoFileName);
  });

  test(
    'missing segment → E_FILES_MISSING and the directory is removed',
    () async {
      await manager.start();
      await enqueue(['ep1']);
      await manager.idle;
      final dir = await store.unitDir(_source, _item, 'ep1');
      File('${dir.path}/v/00002.ts').deleteSync();
      expect(await library.video(_source, _item, 'ep1'), isNull);
      final u = (await repo.unit(_source, _item, 'ep1'))!;
      expect(u.status, DownloadStatus.failed);
      expect(u.errorCode, downloadFilesMissing);
      expect(dir.existsSync(), isFalse);
    },
  );

  test('write failure → E_STORAGE', () async {
    // 让剧集目录的位置被一个文件占住，创建目录失败。
    final dir = await store.unitDir(_source, _item, 'ep1');
    await dir.parent.create(recursive: true);
    await File(dir.path).writeAsString('blocker');
    await manager.start();
    await enqueue(['ep1']);
    await manager.idle;
    final u = (await repo.unit(_source, _item, 'ep1'))!;
    expect(u.status, DownloadStatus.failed);
    expect(u.errorCode, downloadStorageError);
  });

  test('start() removes leftover *.part files', () async {
    final dir = await store.unitDir(_source, _item, 'ep1');
    final part = File('${dir.path}/v/00001.ts.part')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('half');
    final keep = File('${dir.path}/v/00002.ts')..writeAsStringSync('keep');
    await manager.start();
    expect(part.existsSync(), isFalse);
    expect(keep.existsSync(), isTrue);
  });

  test(
    'enqueue before start() finishes does not race the *.part cleanup',
    () async {
      final dir = await store.unitDir(_source, _item, 'ep1');
      File('${dir.path}/v/00001.ts.part')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('half');
      final starting = manager.start();
      await enqueue(['ep1']);
      await starting;
      await manager.idle;
      expect(
        (await repo.unit(_source, _item, 'ep1'))!.status,
        DownloadStatus.done,
      );
    },
  );

  test('pausing a running video aborts its requests', () async {
    await manager.start();
    await enqueue(['ep1']);
    // 认领后立即暂停。
    while ((await repo.unit(_source, _item, 'ep1'))!.status !=
        DownloadStatus.running) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await manager.pause((await repo.unit(_source, _item, 'ep1'))!);
    await manager.idle;
    expect(
      (await repo.unit(_source, _item, 'ep1'))!.status,
      DownloadStatus.paused,
    );
  });
}
