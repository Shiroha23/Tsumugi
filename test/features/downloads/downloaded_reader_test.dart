import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/storage/app_database.dart';
import 'package:tsumugi/features/comic/reader/reader_providers.dart';
import 'package:tsumugi/features/downloads/download_dialog.dart';
import 'package:tsumugi/features/novel/reader/novel_reader_providers.dart';
import 'package:tsumugi/shared/download/download_paths.dart';
import 'package:tsumugi/shared/download/providers.dart';
import 'package:tsumugi/shared/library/library_item.dart';
import 'package:tsumugi/sources/model/common.dart';
import 'package:tsumugi/sources/model/content.dart';
import 'package:tsumugi/sources/model/manifest.dart';
import 'package:tsumugi/sources/source.dart';

import '../../core/storage/test_database.dart';
import '../../sources/runtime/runtime_support.dart';

const _sourceId = 'com.example.dl';
const _itemId = '/book/1';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
);

const _detail = Detail(
  id: _itemId,
  title: '虚构作品',
  units: [
    Unit(id: '/c/1', title: '第 1 章'),
    Unit(id: '/c/2', title: '第 2 章'),
  ],
);

/// 可切换“离线”的源：离线时 detail / content 都抛出网络错误。
class _Source {
  _Source(this.type);

  final MediaType type;
  bool offline = false;
  final contentCalls = <String>[];

  Source build() => FakeSource(
    SourceManifest.fromJson(
      jsonDecode(fakeManifestJson(_sourceId, type: type))
          as Map<String, dynamic>,
    ),
    onDetail: (_) async {
      if (offline) throw const SourceException(SourceErrorCode.network);
      return _detail;
    },
    onContent: (id) async {
      contentCalls.add(id);
      if (offline) throw const SourceException(SourceErrorCode.network);
      return type == MediaType.comic
          ? const ComicContent(
              images: [
                ImageRef(url: 'https://img.example.com/1.png'),
                ImageRef(url: 'https://img.example.com/2.png'),
              ],
            )
          : const NovelContent(
              text:
                  '<p>正文</p><img src="https://img.example.com/a.png" alt="插图">'
                  '<img src="https://img.example.com/b.png" alt="缺失">',
              html: true,
            );
    },
  );
}

/// 像页面一样保持监听后再读取（自动释放的 provider 只被 read 时会在异步间隙后被释放）。
Future<T> _read<T>(
  ProviderContainer container,
  ProviderListenable<Object?> provider,
  ProviderListenable<Future<T>> future,
) {
  final sub = container.listen(provider, (_, _) {});
  addTearDown(sub.close);
  return container.read(future);
}

void main() {
  late Directory tmp;
  late AppDatabase db;
  late ProviderContainer container;
  late _Source source;

  Future<void> setUpFor(MediaType type) async {
    source = _Source(type);
    final instance = source.build();
    container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        downloadStoreProvider.overrideWithValue(
          DownloadStore(() => Directory('${tmp.path}/downloads')),
        ),
        comicReaderSourceProvider(_sourceId).overrideWith((_) => instance),
        novelReaderSourceProvider(_sourceId).overrideWith((_) => instance),
        downloadManagerProvider.overrideWith((ref) {
          final m = DownloadManager(
            repository: ref.watch(downloadRepositoryProvider),
            store: ref.watch(downloadStoreProvider),
            sourceFor: (_) async => instance,
            fetchImage: (_, _) async => Uint8List.fromList(_png),
          );
          m.start().ignore();
          ref.onDispose(m.dispose);
          return m;
        }),
      ],
    );
    final manager = container.read(downloadManagerProvider);
    await manager.enqueue(
      LibraryItem(
        sourceId: _sourceId,
        itemId: _itemId,
        title: '虚构作品',
        mediaType: type,
      ),
      _detail,
      [DownloadRequestUnit(_detail.units.first, groupName: '默认', index: 0)],
    );
    await manager.idle;
    source.contentCalls.clear();
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tsumugi_dlr_');
    db = openTestDatabase();
  });
  tearDown(() async {
    container.dispose();
    await db.close();
    await tmp.delete(recursive: true);
  });

  test('漫画：已下载的章节从本地读取，不调用 content()；离线时目录用快照', () async {
    await setUpFor(MediaType.comic);
    source.offline = true;
    final chapter = await _read(
      container,
      comicReaderChapterProvider(_sourceId, _itemId, '/c/1'),
      comicReaderChapterProvider(_sourceId, _itemId, '/c/1').future,
    );
    expect(chapter.localFiles, hasLength(2));
    expect(source.contentCalls, isEmpty);
    final detail = await _read(
      container,
      comicReaderDetailProvider(_sourceId, _itemId),
      comicReaderDetailProvider(_sourceId, _itemId).future,
    );
    expect(detail.units.map((u) => u.id), ['/c/1', '/c/2']);

    // 未下载的章节离线时照常失败。
    await expectLater(
      _read(
        container,
        comicReaderChapterProvider(_sourceId, _itemId, '/c/2'),
        comicReaderChapterProvider(_sourceId, _itemId, '/c/2').future,
      ),
      throwsA(isA<SourceException>()),
    );
  });

  test('漫画：文件缺失时回退到网络并标为未下载', () async {
    await setUpFor(MediaType.comic);
    final dir = await container
        .read(downloadStoreProvider)
        .unitDir(_sourceId, _itemId, '/c/1');
    await File('${dir.path}/0001.png').delete();
    final chapter = await _read(
      container,
      comicReaderChapterProvider(_sourceId, _itemId, '/c/1'),
      comicReaderChapterProvider(_sourceId, _itemId, '/c/1').future,
    );
    expect(chapter.localFiles, isNull);
    expect(source.contentCalls, ['/c/1']);
    final unit = await container
        .read(downloadRepositoryProvider)
        .unit(_sourceId, _itemId, '/c/1');
    expect(unit!.status, DownloadStatus.failed);
    expect(unit.errorCode, downloadFilesMissing);
  });

  test('小说：离线读取正文，图片按映射加载，文件缺失的只缺该图', () async {
    await setUpFor(MediaType.novel);
    final dir = await container
        .read(downloadStoreProvider)
        .unitDir(_sourceId, _itemId, '/c/1');
    await File('${dir.path}/img-0002.png').delete();
    source.offline = true;
    final chapter = await _read(
      container,
      novelReaderChapterProvider(_sourceId, _itemId, '/c/1'),
      novelReaderChapterProvider(_sourceId, _itemId, '/c/1').future,
    );
    expect(source.contentCalls, isEmpty);
    expect(chapter.plainText, contains('正文'));
    expect(chapter.localImages!.keys, ['https://img.example.com/a.png']);
    expect(
      chapter.localImages!['https://img.example.com/a.png'],
      endsWith('img-0001.png'),
    );
    expect(isValidDownloadFileName('img-0001.png'), isTrue);
  });

  testWidgets('下载对话框：按范围加入队列', (tester) async {
    final added = <List<String>>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          downloadManagerProvider.overrideWithValue(_RecordingManager(added)),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDownloadDialog(
                context,
                item: const LibraryItem(
                  sourceId: _sourceId,
                  itemId: _itemId,
                  title: '虚构作品',
                  mediaType: MediaType.comic,
                ),
                detail: const Detail(
                  id: _itemId,
                  title: '虚构作品',
                  groups: [
                    UnitGroup(
                      name: '线路 A',
                      units: [
                        Unit(id: 'a1', title: 'A1'),
                        Unit(id: 'a2', title: 'A2'),
                      ],
                    ),
                    UnitGroup(
                      name: '线路 B',
                      units: [
                        Unit(id: 'b1', title: 'B1'),
                        Unit(id: 'b2', title: 'B2'),
                        Unit(id: 'b3', title: 'B3'),
                      ],
                    ),
                  ],
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('全部章节（2 章）'), findsOneWidget);
    await tester.tap(find.text('线路 A（2 章）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('线路 B（3 章）').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('起止章节'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('download-range-从')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2. B2').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始下载'));
    await tester.pumpAndSettle();
    expect(added, [
      ['线路 B:1:b2', '线路 B:2:b3'],
    ]);
  });
}

class _RecordingManager implements DownloadManager {
  _RecordingManager(this.added);

  final List<List<String>> added;

  @override
  Future<int> enqueue(
    LibraryItem item,
    Detail detail,
    List<DownloadRequestUnit> units,
  ) async {
    added.add([
      for (final u in units) '${u.groupName}:${u.index}:${u.unit.id}',
    ]);
    return units.length;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
