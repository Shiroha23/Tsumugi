import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/storage/app_database.dart';
import 'package:tsumugi/shared/download/download_paths.dart';
import 'package:tsumugi/shared/download/providers.dart';
import 'package:tsumugi/shared/download/unit_manifest.dart';
import 'package:tsumugi/shared/library/library_item.dart';
import 'package:tsumugi/shared/novel/novel_document.dart';
import 'package:tsumugi/sources/model/common.dart';
import 'package:tsumugi/sources/model/content.dart';
import 'package:tsumugi/sources/model/manifest.dart';
import 'package:tsumugi/sources/runtime/source_runtime.dart';
import 'package:tsumugi/sources/source.dart';

import '../../core/storage/test_database.dart';
import '../../sources/runtime/runtime_support.dart';

const _comicSource = 'com.example.comic';
const _novelSource = 'com.example.novel';
const _otherSource = 'com.example.other';

/// 1×1 PNG。
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
);

Uint8List _pngFor(String url) =>
    Uint8List.fromList([..._png, ...utf8.encode(url)]);

SourceManifest _manifest(String id, MediaType type) => SourceManifest.fromJson(
  jsonDecode(fakeManifestJson(id, type: type)) as Map<String, dynamic>,
);

class _Harness {
  _Harness(this.root) {
    store = DownloadStore(() => root);
    repo = DownloadRepository(db);
    library = DownloadLibrary(repository: repo, store: store);
  }

  final Directory root;
  final AppDatabase db = openTestDatabase();
  late final DownloadStore store;
  late final DownloadRepository repo;
  late final DownloadLibrary library;
  late DownloadManager manager = _newManager();

  /// unitId → 图片地址；可在测试中修改（模拟源换图）。
  final comicPages = <String, List<String>>{};

  /// unitId → 小说 HTML 正文。
  final novelText = <String, String>{};

  /// 抛出错误的 sourceId → 错误（`sourceFor` 抛出）。
  final sourceErrors = <String, Object>{};

  /// 图片地址 → 要抛出的错误（只抛一次）。
  final imageErrors = <String, Object>{};

  /// 图片请求的地址（按顺序）。
  final fetched = <String>[];

  /// 设置后 content() 会等它完成。
  Completer<void>? contentGate;

  int maxImageBytes = 10 * 1024 * 1024;
  int maxTotalImageBytes = 100 * 1024 * 1024;
  int maxComicPages = 2000;
  int maxNovelImages = 500;

  DownloadManager _newManager() => DownloadManager(
    repository: repo,
    store: store,
    sourceFor: (id) async {
      if (sourceErrors[id] case final e?) throw e;
      final type = id == _novelSource ? MediaType.novel : MediaType.comic;
      return FakeSource(
        _manifest(id, type),
        onContent: (unitId) async {
          await contentGate?.future;
          if (type == MediaType.novel) {
            return NovelContent(text: novelText[unitId] ?? '', html: true);
          }
          return ComicContent(
            images: [
              for (final u in comicPages[unitId] ?? const <String>[])
                ImageRef(
                  url: u,
                  headers: const {'Referer': 'https://example.com/'},
                ),
            ],
          );
        },
      );
    },
    fetchImage: (sourceId, ref) async {
      fetched.add(ref.url);
      if (imageErrors.remove(ref.url) case final e?) throw e;
      return _pngFor(ref.url);
    },
    maxNovelImageBytes: maxImageBytes,
    maxNovelTotalImageBytes: maxTotalImageBytes,
    maxComicPages: maxComicPages,
    maxNovelImages: maxNovelImages,
  );

  /// 模拟应用重启：新的管理器实例。
  Future<void> restart() async {
    manager.dispose();
    await manager.idle;
    manager = _newManager();
    await manager.start();
  }

  Future<void> enqueue(
    String sourceId,
    String itemId,
    MediaType type,
    List<String> unitIds,
  ) async {
    final detail = Detail(
      id: itemId,
      title: '虚构作品',
      units: [for (final u in unitIds) Unit(id: u, title: '章节 $u')],
    );
    await manager.enqueue(
      LibraryItem(
        sourceId: sourceId,
        itemId: itemId,
        title: '虚构作品',
        mediaType: type,
      ),
      detail,
      [
        for (final (i, u) in detail.units.indexed)
          DownloadRequestUnit(u, groupName: '默认', index: i),
      ],
    );
  }

  Future<DownloadUnit> unit(
    String sourceId,
    String itemId,
    String unitId,
  ) async => (await repo.unit(sourceId, itemId, unitId))!;

  Future<Directory> dir(String sourceId, String itemId, String unitId) =>
      store.unitDir(sourceId, itemId, unitId);

  Future<void> dispose() async {
    manager.dispose();
    await manager.idle;
    await db.close();
  }
}

void main() {
  late Directory tmp;
  late _Harness h;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tsumugi_dl_');
    h = _Harness(Directory('${tmp.path}${Platform.pathSeparator}downloads'));
    await h.manager.start();
  });
  tearDown(() async {
    await h.dispose();
    await tmp.delete(recursive: true);
  });

  group('路径', () {
    test('只由哈希与序号构成，不含源返回的字符串', () async {
      const itemId = '../../etc/passwd';
      const unitId = r'..\..\C:\Windows?x=1';
      final dir = await h.store.unitDir('evil/../id', itemId, unitId);
      final rel = dir.path.substring(h.root.path.length + 1);
      final parts = rel.split(Platform.pathSeparator);
      expect(parts, hasLength(3));
      for (final p in parts) {
        expect(p, matches(RegExp(r'^[0-9a-f]{32}$')));
      }
      expect(parts, unitPathSegments('evil/../id', itemId, unitId));
      expect(comicPageFileName(0, 'png'), '0001.png');
      expect(comicPageFileName(41, 'webp'), '0042.webp');
      expect(novelImageFileName(2, 'jpg'), 'img-0003.jpg');
    });

    test('文件名校验拒绝目录穿越与未知格式', () {
      expect(isValidDownloadFileName('0001.png'), isTrue);
      expect(isValidDownloadFileName('img-0002.gif'), isTrue);
      for (final bad in [
        '../0001.png',
        '0001.png/../../x',
        r'..\0001.png',
        '0001.exe',
        'unit.json',
        'img-1.png',
        '',
      ]) {
        expect(isValidDownloadFileName(bad), isFalse, reason: bad);
      }
    });

    test('来源标识与请求头顺序无关，地址或请求头变化时不同', () {
      final a = imageSourceKey('https://img.example.com/1.png', {
        'A': '1',
        'B': '2',
      });
      final b = imageSourceKey('https://img.example.com/1.png', {
        'B': '2',
        'A': '1',
      });
      expect(a, b);
      expect(
        imageSourceKey('https://img.example.com/1.png', {'A': '1'}),
        isNot(a),
      );
      expect(
        imageSourceKey('https://img.example.com/2.png', {'A': '1', 'B': '2'}),
        isNot(a),
      );
      expect(imageSourceKey('https://img.example.com/1.png', null), isNot(a));
    });

    test('unit.json 指向非法文件名时视为损坏', () {
      final key = sha256Hex('x');
      final bad = jsonEncode({
        'version': 1,
        'kind': 'comic',
        'files': [
          {'key': key, 'file': '../../outside.png'},
        ],
      });
      expect(() => UnitManifest.decode(bad), throwsFormatException);
      final badMap = jsonEncode({
        'version': 1,
        'kind': 'novel',
        'files': [
          {'key': key, 'file': 'img-0001.png'},
        ],
        'images': {'https://img.example.com/a.png': 'img-0002.png'},
      });
      expect(() => UnitManifest.decode(badMap), throwsFormatException);
    });
  });

  group('漫画', () {
    test('下载全部页：按文件头取扩展名，写 unit.json 与完成标记', () async {
      h.comicPages['/c/1'] = [
        'https://img.example.com/1.png',
        'https://img.example.com/2.png',
      ];
      await h.enqueue(_comicSource, '/b/1', MediaType.comic, ['/c/1']);
      await h.manager.idle;

      final u = await h.unit(_comicSource, '/b/1', '/c/1');
      expect(u.status, DownloadStatus.done);
      expect(u.completedFiles, 2);
      expect(u.totalFiles, 2);
      final dir = await h.dir(_comicSource, '/b/1', '/c/1');
      final names = dir.listSync().map((e) => e.uri.pathSegments.last).toSet();
      expect(names, {'0001.png', '0002.png', unitFileName, doneFileName});
      final pages = await h.library.comicPages(_comicSource, '/b/1', '/c/1');
      expect(pages, hasLength(2));
      expect(
        await pages![1].readAsBytes(),
        _pngFor('https://img.example.com/2.png'),
      );
    });

    test('续传：来源标识一致时只下载未写完的文件', () async {
      h.comicPages['/c/1'] = [
        'https://img.example.com/1.png',
        'https://img.example.com/2.png',
        'https://img.example.com/3.png',
      ];
      h.imageErrors['https://img.example.com/2.png'] = const SourceException(
        SourceErrorCode.network,
      );
      await h.enqueue(_comicSource, '/b/1', MediaType.comic, ['/c/1']);
      await h.manager.idle;
      var u = await h.unit(_comicSource, '/b/1', '/c/1');
      expect(u.status, DownloadStatus.failed);
      expect(u.errorCode, 'E_NETWORK');
      expect(u.completedFiles, 1);
      expect(await h.library.comicPages(_comicSource, '/b/1', '/c/1'), isNull);

      h.fetched.clear();
      await h.manager.resume(u);
      await h.manager.idle;
      u = await h.unit(_comicSource, '/b/1', '/c/1');
      expect(u.status, DownloadStatus.done);
      expect(h.fetched, [
        'https://img.example.com/2.png',
        'https://img.example.com/3.png',
      ]);
    });

    test('续传：源换了图片时丢弃已下载的文件，从头下载', () async {
      h.comicPages['/c/1'] = [
        'https://img.example.com/1.png',
        'https://img.example.com/2.png',
      ];
      h.imageErrors['https://img.example.com/2.png'] = const SourceException(
        SourceErrorCode.network,
      );
      await h.enqueue(_comicSource, '/b/1', MediaType.comic, ['/c/1']);
      await h.manager.idle;

      // 源换了第一张图（顺序 / 数量变化同理）。
      h.comicPages['/c/1'] = [
        'https://img.example.com/1b.png',
        'https://img.example.com/2.png',
      ];
      h.fetched.clear();
      await h.manager.resume(await h.unit(_comicSource, '/b/1', '/c/1'));
      await h.manager.idle;
      expect(h.fetched, [
        'https://img.example.com/1b.png',
        'https://img.example.com/2.png',
      ]);
      final pages = await h.library.comicPages(_comicSource, '/b/1', '/c/1');
      expect(
        await pages![0].readAsBytes(),
        _pngFor('https://img.example.com/1b.png'),
      );
    });

    test('无法识别的图片格式视为失败', () async {
      h.comicPages['/c/1'] = ['https://img.example.com/1.png'];
      final m = DownloadManager(
        repository: h.repo,
        store: h.store,
        sourceFor: (id) async => FakeSource(
          _manifest(id, MediaType.comic),
          onContent: (_) async => const ComicContent(
            images: [ImageRef(url: 'https://img.example.com/1.png')],
          ),
        ),
        fetchImage: (_, _) async => Uint8List.fromList(utf8.encode('<html>')),
      );
      h.manager.dispose();
      h.manager = m;
      await m.start();
      await h.enqueue(_comicSource, '/b/1', MediaType.comic, ['/c/1']);
      await m.idle;
      final u = await h.unit(_comicSource, '/b/1', '/c/1');
      expect(u.status, DownloadStatus.failed);
      expect(u.errorCode, 'E_PARSE');
      final dir = await h.dir(_comicSource, '/b/1', '/c/1');
      expect(await DownloadStore.isDone(dir), isFalse);
    });

    test('文件缺失或记录损坏时回退到网络并标为未下载', () async {
      h.comicPages['/c/1'] = [
        'https://img.example.com/1.png',
        'https://img.example.com/2.png',
      ];
      h.comicPages['/c/2'] = ['https://img.example.com/3.png'];
      await h.enqueue(_comicSource, '/b/1', MediaType.comic, ['/c/1', '/c/2']);
      await h.manager.idle;

      final dir1 = await h.dir(_comicSource, '/b/1', '/c/1');
      await DownloadStore.fileIn(dir1, '0002.png').delete();
      expect(await h.library.comicPages(_comicSource, '/b/1', '/c/1'), isNull);
      final u1 = await h.unit(_comicSource, '/b/1', '/c/1');
      expect(u1.status, DownloadStatus.failed);
      expect(u1.errorCode, downloadFilesMissing);
      expect(await dir1.exists(), isFalse);

      final dir2 = await h.dir(_comicSource, '/b/1', '/c/2');
      await DownloadStore.fileIn(dir2, unitFileName).writeAsString('{not json');
      expect(await h.library.comicPages(_comicSource, '/b/1', '/c/2'), isNull);
      expect(
        (await h.unit(_comicSource, '/b/1', '/c/2')).errorCode,
        downloadFilesMissing,
      );
    });

    test('没有完成标记的 unit 视为未下载', () async {
      h.comicPages['/c/1'] = ['https://img.example.com/1.png'];
      await h.enqueue(_comicSource, '/b/1', MediaType.comic, ['/c/1']);
      await h.manager.idle;
      final dir = await h.dir(_comicSource, '/b/1', '/c/1');
      await DownloadStore.fileIn(dir, doneFileName).delete();
      expect(await h.library.comicPages(_comicSource, '/b/1', '/c/1'), isNull);
    });
  });

  group('队列', () {
    test('同一源一次一个 unit，不同源最多 2 个', () async {
      for (final u in ['/c/1', '/c/2']) {
        h.comicPages[u] = ['https://img.example.com$u.png'];
      }
      final gate = h.contentGate = Completer<void>();
      await h.enqueue(_comicSource, '/b/1', MediaType.comic, ['/c/1', '/c/2']);
      await h.enqueue(_otherSource, '/b/2', MediaType.comic, ['/c/1']);
      await h.enqueue('com.example.third', '/b/3', MediaType.comic, ['/c/1']);
      await pumpEventQueue();

      final running = [
        for (final u in await h.repo.allUnits())
          if (u.status == DownloadStatus.running) (u.sourceId, u.unitId),
      ];
      expect(
        running,
        unorderedEquals([(_comicSource, '/c/1'), (_otherSource, '/c/1')]),
      );
      gate.complete();
      await h.manager.idle;
      expect((await h.repo.allUnits()).map((u) => u.status).toSet(), {
        DownloadStatus.done,
      });
    });

    test('需要验证时暂停该源的全部下载，验证完成后继续', () async {
      h.comicPages['/c/1'] = ['https://img.example.com/1.png'];
      h.comicPages['/c/2'] = ['https://img.example.com/2.png'];
      h.sourceErrors[_comicSource] = const SourceException(
        SourceErrorCode.challenge,
      );
      await h.enqueue(_comicSource, '/b/1', MediaType.comic, ['/c/1', '/c/2']);
      await h.manager.idle;

      final u1 = await h.unit(_comicSource, '/b/1', '/c/1');
      final u2 = await h.unit(_comicSource, '/b/1', '/c/2');
      expect(u1.status, DownloadStatus.paused);
      expect(u1.errorCode, 'E_CHALLENGE');
      expect(u1.pausesSource, isTrue);
      // 同源的其余 unit 不再尝试。
      expect(u2.status, DownloadStatus.queued);

      h.sourceErrors.remove(_comicSource);
      await h.manager.resumeSource(_comicSource);
      await h.manager.idle;
      expect(
        (await h.unit(_comicSource, '/b/1', '/c/1')).status,
        DownloadStatus.done,
      );
      expect(
        (await h.unit(_comicSource, '/b/1', '/c/2')).status,
        DownloadStatus.done,
      );
    });

    test('源不可用时暂停该源，不影响其他源', () async {
      h.comicPages['/c/1'] = ['https://img.example.com/1.png'];
      h.sourceErrors[_comicSource] = const SourceUnavailableException(
        _comicSource,
        '已禁用',
      );
      await h.enqueue(_comicSource, '/b/1', MediaType.comic, ['/c/1']);
      await h.enqueue(_otherSource, '/b/2', MediaType.comic, ['/c/1']);
      await h.manager.idle;
      final u = await h.unit(_comicSource, '/b/1', '/c/1');
      expect(u.status, DownloadStatus.paused);
      expect(u.errorCode, downloadSourceUnavailable);
      expect(
        (await h.unit(_otherSource, '/b/2', '/c/1')).status,
        DownloadStatus.done,
      );
    });

    test('退出时进行中的 unit 回到 queued，下次启动后继续', () async {
      h.comicPages['/c/1'] = ['https://img.example.com/1.png'];
      h.contentGate = Completer<void>();
      await h.enqueue(_comicSource, '/b/1', MediaType.comic, ['/c/1']);
      await pumpEventQueue();
      expect(
        (await h.unit(_comicSource, '/b/1', '/c/1')).status,
        DownloadStatus.running,
      );

      h.manager.dispose();
      h.contentGate!.complete();
      await h.manager.idle;
      // 被中断的任务不写状态，数据库里仍是 running（相当于进程被结束）。
      expect(
        (await h.unit(_comicSource, '/b/1', '/c/1')).status,
        DownloadStatus.running,
      );

      h.contentGate = null;
      h.manager = h._newManager();
      await h.manager.start();
      await h.manager.idle;
      expect(
        (await h.unit(_comicSource, '/b/1', '/c/1')).status,
        DownloadStatus.done,
      );
    });

    test('暂停进行中的 unit 后不再写入；删除会移除文件与记录', () async {
      h.comicPages['/c/1'] = ['https://img.example.com/1.png'];
      final gate = h.contentGate = Completer<void>();
      await h.enqueue(_comicSource, '/b/1', MediaType.comic, ['/c/1']);
      await pumpEventQueue();
      await h.manager.pause(await h.unit(_comicSource, '/b/1', '/c/1'));
      gate.complete();
      await h.manager.idle;
      expect(
        (await h.unit(_comicSource, '/b/1', '/c/1')).status,
        DownloadStatus.paused,
      );

      h.contentGate = null;
      await h.manager.resume(await h.unit(_comicSource, '/b/1', '/c/1'));
      await h.manager.idle;
      final dir = await h.dir(_comicSource, '/b/1', '/c/1');
      expect(await DownloadStore.isDone(dir), isTrue);

      await h.manager.deleteUnit(await h.unit(_comicSource, '/b/1', '/c/1'));
      expect(await h.repo.unit(_comicSource, '/b/1', '/c/1'), isNull);
      expect(await h.repo.item(_comicSource, '/b/1'), isNull);
      expect(await dir.exists(), isFalse);
    });

    test('已完成的 unit 不重复加入；条目快照可离线读取', () async {
      h.comicPages['/c/1'] = ['https://img.example.com/1.png'];
      await h.enqueue(_comicSource, '/b/1', MediaType.comic, ['/c/1']);
      await h.manager.idle;
      h.fetched.clear();
      await h.enqueue(_comicSource, '/b/1', MediaType.comic, ['/c/1']);
      await h.manager.idle;
      expect(h.fetched, isEmpty);
      final snapshot = await h.library.detailSnapshot(_comicSource, '/b/1');
      expect(snapshot?.units.single.id, '/c/1');
    });

    test('清空全部下载', () async {
      h.comicPages['/c/1'] = ['https://img.example.com/1.png'];
      await h.enqueue(_comicSource, '/b/1', MediaType.comic, ['/c/1']);
      await h.manager.idle;
      expect(await h.store.totalBytes(), greaterThan(0));
      await h.manager.deleteAll();
      expect(await h.store.totalBytes(), 0);
      expect(await h.repo.allUnits(), isEmpty);
    });
  });

  group('审查后补充', () {
    test('漫画超过页数上限时以 E_LIMIT 失败，不写任何页', () async {
      h.manager.dispose();
      h.maxComicPages = 2;
      h.manager = h._newManager();
      await h.manager.start();
      h.comicPages['/c/1'] = [
        for (var i = 0; i < 3; i++) 'https://img.example.com/$i.png',
      ];
      await h.enqueue(_comicSource, '/b/1', MediaType.comic, ['/c/1']);
      await h.manager.idle;
      final u = await h.unit(_comicSource, '/b/1', '/c/1');
      expect(u.status, DownloadStatus.failed);
      expect(u.errorCode, 'E_LIMIT');
      expect(h.fetched, isEmpty);
    });

    test('继续一个条目时一并恢复因验证暂停的源（同源其他条目暂停）', () async {
      h.comicPages['/c/1'] = ['https://img.example.com/1.png'];
      h.sourceErrors[_comicSource] = const SourceException(
        SourceErrorCode.challenge,
      );
      await h.enqueue(_comicSource, '/b/1', MediaType.comic, ['/c/1']);
      await h.manager.idle;
      await h.enqueue(_comicSource, '/b/2', MediaType.comic, ['/c/1']);
      await h.manager.idle;
      expect((await h.unit(_comicSource, '/b/1', '/c/1')).pausesSource, isTrue);
      expect(
        (await h.unit(_comicSource, '/b/2', '/c/1')).status,
        DownloadStatus.queued,
      );

      h.sourceErrors.remove(_comicSource);
      await h.manager.resumeItem(_comicSource, '/b/2');
      await h.manager.idle;
      expect(
        (await h.unit(_comicSource, '/b/2', '/c/1')).status,
        DownloadStatus.done,
      );
      expect(
        (await h.unit(_comicSource, '/b/1', '/c/1')).status,
        DownloadStatus.done,
      );
    });

    test('任务结束时只在仍为 running 时写入结果（暂停与认领的竞态）', () async {
      h.comicPages['/c/1'] = ['https://img.example.com/1.png'];
      final gate = h.contentGate = Completer<void>();
      await h.enqueue(_comicSource, '/b/1', MediaType.comic, ['/c/1']);
      await pumpEventQueue();
      // 模拟暂停写入状态、但取消没有找到任务（任务在其后才被创建）。
      await h.repo.setStatus(
        _comicSource,
        '/b/1',
        '/c/1',
        DownloadStatus.paused,
      );
      gate.complete();
      await h.manager.idle;
      expect(
        (await h.unit(_comicSource, '/b/1', '/c/1')).status,
        DownloadStatus.paused,
      );
    });

    test('认领后、任务开始前被暂停：不再下载', () async {
      h.comicPages['/c/1'] = ['https://img.example.com/1.png'];
      final gate = h.contentGate = Completer<void>();
      await h.enqueue(_comicSource, '/b/1', MediaType.comic, ['/c/1']);
      await pumpEventQueue();
      // 只改数据库（模拟 pause 没找到任务）。
      await h.repo.setStatus(
        _comicSource,
        '/b/1',
        '/c/1',
        DownloadStatus.paused,
      );
      gate.complete();
      await h.manager.idle;
      expect(h.fetched, isEmpty);
      final dir = await h.dir(_comicSource, '/b/1', '/c/1');
      expect(await DownloadStore.isDone(dir), isFalse);
    });

    test('markBroken 只对 done 生效，不删除正在重新下载的目录', () async {
      h.comicPages['/c/1'] = ['https://img.example.com/1.png'];
      await h.enqueue(_comicSource, '/b/1', MediaType.comic, ['/c/1']);
      await h.manager.idle;
      await h.repo.setStatus(
        _comicSource,
        '/b/1',
        '/c/1',
        DownloadStatus.running,
      );
      await h.library.markBroken(_comicSource, '/b/1', '/c/1', '迟到的回调');
      final dir = await h.dir(_comicSource, '/b/1', '/c/1');
      expect(await dir.exists(), isTrue);
      expect(
        (await h.unit(_comicSource, '/b/1', '/c/1')).status,
        DownloadStatus.running,
      );
    });

    test('小说超过图片数量上限的图片保留占位，不请求', () async {
      h.manager.dispose();
      h.maxNovelImages = 1;
      h.manager = h._newManager();
      await h.manager.start();
      h.novelText['/c/1'] =
          '<img src="https://img.example.com/a.png">'
          '<img src="https://img.example.com/b.png">'
          '<img src="https://img.example.com/c.png">';
      h.imageErrors['https://img.example.com/a.png'] = const SourceException(
        SourceErrorCode.network,
      );
      await h.enqueue(_novelSource, '/b/1', MediaType.novel, ['/c/1']);
      await h.manager.idle;
      expect(
        (await h.unit(_novelSource, '/b/1', '/c/1')).status,
        DownloadStatus.failed,
      );
      h.fetched.clear();
      await h.manager.resume(await h.unit(_novelSource, '/b/1', '/c/1'));
      await h.manager.idle;
      expect(h.fetched, ['https://img.example.com/a.png']);
      final chapter = await h.library.novelChapter(
        _novelSource,
        '/b/1',
        '/c/1',
      );
      expect(chapter!.localImages!.keys, ['https://img.example.com/a.png']);
    });
  });

  group('小说', () {
    test('正文与正文图片：按映射从本地加载，超限的图片保留占位', () async {
      h.manager.dispose();
      h.maxImageBytes = _pngFor('https://img.example.com/a.png').length;
      h.manager = h._newManager();
      await h.manager.start();
      h.novelText['/c/1'] =
          '<p>第一段</p><img src="https://img.example.com/a.png" alt="甲">'
          '<p><b>第二段</b></p><img src="https://img.example.com/a.png">'
          '<img src="https://img.example.com/too-large-image.png" alt="乙"><hr>';
      await h.enqueue(_novelSource, '/b/1', MediaType.novel, ['/c/1']);
      await h.manager.idle;

      final u = await h.unit(_novelSource, '/b/1', '/c/1');
      expect(u.status, DownloadStatus.done);
      // 同一地址只下载一次。
      expect(h.fetched, [
        'https://img.example.com/a.png',
        'https://img.example.com/too-large-image.png',
      ]);
      final chapter = await h.library.novelChapter(
        _novelSource,
        '/b/1',
        '/c/1',
      );
      expect(chapter, isNotNull);
      expect(chapter!.plainText, contains('第二段'));
      expect(chapter.blocks.whereType<NovelImage>(), hasLength(3));
      expect(chapter.blocks.last, isA<NovelDivider>());
      final local = chapter.localImages!;
      expect(local.keys, ['https://img.example.com/a.png']);
      expect(
        await File(local['https://img.example.com/a.png']!).readAsBytes(),
        _pngFor('https://img.example.com/a.png'),
      );
      final dir = await h.dir(_novelSource, '/b/1', '/c/1');
      expect(dir.listSync().map((e) => e.uri.pathSegments.last).toSet(), {
        'img-0001.png',
        chapterFileName,
        unitFileName,
        doneFileName,
      });
    });

    test('图片文件缺失时只缺该图，chapter.json 损坏时回退到网络', () async {
      h.novelText['/c/1'] =
          '<p>正文</p><img src="https://img.example.com/a.png">';
      await h.enqueue(_novelSource, '/b/1', MediaType.novel, ['/c/1']);
      await h.manager.idle;
      final dir = await h.dir(_novelSource, '/b/1', '/c/1');
      await DownloadStore.fileIn(dir, 'img-0001.png').delete();
      final chapter = await h.library.novelChapter(
        _novelSource,
        '/b/1',
        '/c/1',
      );
      expect(chapter!.localImages, isEmpty);

      await DownloadStore.fileIn(dir, chapterFileName).writeAsString(
        jsonEncode({
          'version': 1,
          'blocks': [
            {'t': 'img', 'url': 'javascript:alert(1)'},
          ],
        }),
      );
      expect(
        await h.library.novelChapter(_novelSource, '/b/1', '/c/1'),
        isNull,
      );
      expect(
        (await h.unit(_novelSource, '/b/1', '/c/1')).errorCode,
        downloadFilesMissing,
      );
    });
  });
}
