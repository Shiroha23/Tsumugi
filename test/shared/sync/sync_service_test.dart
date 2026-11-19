import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/storage/app_database.dart';
import 'package:tsumugi/shared/library/library_item.dart';
import 'package:tsumugi/shared/sync/sync_document.dart';
import 'package:tsumugi/shared/sync/sync_exception.dart';
import 'package:tsumugi/shared/sync/sync_service.dart';
import 'package:tsumugi/shared/sync/sync_store.dart';
import 'package:tsumugi/sources/model/common.dart';
import 'package:tsumugi/sources/registry/installed_source.dart';

import 'sync_test_support.dart';

const _remotePath = '/Tsumugi/sync-v1.json';

LibraryItem _item(String id, {String? title}) => LibraryItem(
  sourceId: 'com.example.comic',
  itemId: id,
  title: title ?? '虚构漫画 $id',
  mediaType: MediaType.comic,
);

String _settingsManifest({String version = '1.0.0', List<String>? hosts}) {
  final json = jsonDecode(
    File('test/fixtures/sources/settings_comic.json').readAsStringSync(),
  ) as Map<String, Object?>;
  return jsonEncode({...json, 'version': version, 'allowedHosts': ?hosts});
}

Matcher _syncError(SyncError error) =>
    throwsA(isA<SyncException>().having((e) => e.error, 'error', error));

void main() {
  late MockServer server;
  late TestDevice a;
  late TestDevice b;

  setUp(() async {
    server = await MockServer.start();
    a = TestDevice(server);
    b = TestDevice(server);
    await a.configure();
    await b.configure();
  });

  tearDown(() async {
    await a.close();
    await b.close();
    await server.close();
  });

  Future<List<String>> shelf(TestDevice d) async => [
    for (final r in await d.db.select(d.db.libraryEntries).get()) r.itemId,
  ];

  SyncDocument remoteDoc() =>
      SyncDocument.decode(server.dav.files[_remotePath]!.bytes);

  test('first sync creates the directory and the file', () async {
    await a.library.add(_item('/book/1'));
    final summary = await a.service.sync();
    expect(summary.uploaded, isTrue);
    expect(server.dav.collections, contains('/Tsumugi/'));
    final put = server.requests.lastWhere((r) => r.method == 'PUT');
    expect(put.headers['if-none-match'], '*');
    final doc = remoteDoc();
    expect(doc.collections[SyncCollections.library]!.values.single.key, [
      'com.example.comic',
      '/book/1',
    ]);
    // 密码不出现在远端文件里。
    expect(
      utf8.decode(gunzipLimited(server.dav.files[_remotePath]!.bytes)),
      isNot(contains(MockWebDav.password)),
    );
  });

  test('two devices exchange shelf and progress both ways', () async {
    await a.library.add(_item('/book/1'));
    await a.history.recordProgress(
      _item('/book/1'),
      unitId: 'c1',
      unitTitle: '第 1 话',
      page: 9,
      pageCount: 10,
    );
    await a.service.sync();
    await b.library.add(_item('/book/2'));
    await b.service.sync();
    expect(await shelf(b), unorderedEquals(['/book/1', '/book/2']));
    final progress = await b.history.latestProgress(
      'com.example.comic',
      '/book/1',
    );
    expect(progress?.page, 9);
    expect(
      await b.history.isUnitRead('com.example.comic', '/book/1', 'c1'),
      isTrue,
    );

    await a.service.sync();
    expect(await shelf(a), unorderedEquals(['/book/1', '/book/2']));

    // 远端未变时第二次同步用 If-None-Match，不重新下载、不写入。
    server.requests.clear();
    final again = await a.service.sync();
    expect(again.uploaded, isFalse);
    final get = server.requests.singleWhere((r) => r.method == 'GET');
    expect(get.headers['if-none-match'], isNotNull);
    expect(server.requests.where((r) => r.method == 'PUT'), isEmpty);
  });

  test(
    'deletions propagate, including after the tombstone was purged',
    () async {
      await a.library.add(_item('/book/1'));
      await a.library.add(_item('/book/2'));
      await a.service.sync();
      await b.service.sync();
      expect(await shelf(b), hasLength(2));

      await b.library.remove('com.example.comic', '/book/1');
      await b.service.sync();
      await a.service.sync();
      expect(await shelf(a), ['/book/2']);

      // 模拟远端墓碑被清理：远端只是没有这条记录。A 上次同步后没改过 /book/2，按删除处理。
      await b.library.remove('com.example.comic', '/book/2');
      await b.service.sync();
      final doc = remoteDoc();
      final purged = SyncDocument(
        collections: {...doc.collections, SyncCollections.library: {}},
      );
      server.dav.files[_remotePath] = (
        bytes: purged.encode(),
        etag: '"purged"',
      );
      await a.service.sync();
      expect(await shelf(a), isEmpty);
    },
  );

  test(
    'records changed while offline survive a missing remote record',
    () async {
      await a.library.add(_item('/book/1'));
      await a.service.sync();
      // 远端被清空（另一台设备删除后墓碑过期），而 A 期间改过这条记录。
      await Future<void>.delayed(const Duration(milliseconds: 3));
      await a.library.setCategory('com.example.comic', '/book/1', '在读');
      final doc = remoteDoc();
      server.dav.files[_remotePath] = (
        bytes: SyncDocument(
          collections: {...doc.collections, SyncCollections.library: {}},
        ).encode(),
        etag: '"emptied"',
      );
      await a.service.sync();
      expect(await shelf(a), ['/book/1']);
      expect(
        remoteDoc()
            .collections[SyncCollections.library]!
            .values
            .single
            .data!['category'],
        '在读',
      );
    },
  );

  test('concurrent first sync: the second device retries after 412', () async {
    await a.library.add(_item('/book/1'));
    await b.library.add(_item('/book/2'));
    // A 先创建了文件；B 以为远端没有文件（GET 时还是 404），PUT 带 If-None-Match: * 得到 412。
    final aSync = a.service.sync();
    await aSync;
    // 让 B 第一次 GET 看到 404：先移走文件，B 下载后再放回。
    final created = server.dav.files.remove(_remotePath)!;
    server.requests.clear();
    final bSync = b.service.sync();
    // 等 B 发出 GET 再放回文件。
    while (!server.requests.any((r) => r.method == 'GET')) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    server.dav.files[_remotePath] = created;
    final summary = await bSync;
    expect(summary.uploaded, isTrue);
    final puts = server.requests.where((r) => r.method == 'PUT').toList();
    expect(puts, hasLength(2), reason: '第一次 412，重新下载合并后再写');
    expect(puts.first.headers['if-none-match'], '*');
    expect(puts.last.headers['if-match'], created.etag);
    await a.service.sync();
    expect(await shelf(a), unorderedEquals(['/book/1', '/book/2']));
    expect(await shelf(b), unorderedEquals(['/book/1', '/book/2']));
  });

  test('412 retries at most three times', () async {
    await a.library.add(_item('/book/1'));
    await a.service.sync();
    await a.library.add(_item('/book/2'));
    server.dav.force412 = 3;
    expect((await a.service.sync()).uploaded, isTrue);
    expect(server.dav.force412, 0);

    await a.library.add(_item('/book/3'));
    server.dav.force412 = 10;
    await expectLater(a.service.sync(), _syncError(SyncError.conflict));
    expect(server.dav.force412, 6, reason: '1 次 + 3 次重试');
    expect((await a.store.ensureState()).lastError, contains('冲突'));
  });

  test(
    'servers without ETag fall back to read-merge-write with a warning',
    () async {
      server.dav.etags = false;
      await a.library.add(_item('/book/1'));
      await a.service.sync();
      await a.library.add(_item('/book/2'));
      await a.service.sync();
      final state = await a.store.ensureState();
      expect(state.conditionalUnsupported, isTrue);
      final put = server.requests.lastWhere((r) => r.method == 'PUT');
      expect(put.headers.containsKey('if-match'), isFalse);
      expect(remoteDoc().collections[SyncCollections.library]!.length, 2);
    },
  );

  test(
    'without ETags a missing remote record is not taken as a deletion',
    () async {
      server.dav.etags = false;
      await a.library.add(_item('/book/1'));
      await a.service.sync();
      // 另一台设备的无条件写入覆盖了 A 刚上传的内容（没有并发保护）。
      final doc = remoteDoc();
      server.dav.files[_remotePath] = (
        bytes: SyncDocument(
          collections: {...doc.collections, SyncCollections.library: {}},
        ).encode(),
        etag: '"unused"',
      );
      await a.service.sync();
      expect(await shelf(a), ['/book/1']);
      expect(remoteDoc().collections[SyncCollections.library], hasLength(1));
    },
  );

  test('weak ETags fall back to unconditional writes', () async {
    server.dav.weakEtags = true;
    await a.library.add(_item('/book/1'));
    await a.service.sync();
    await a.library.add(_item('/book/2'));
    await a.service.sync();
    expect((await a.store.ensureState()).conditionalUnsupported, isTrue);
    final put = server.requests.lastWhere((r) => r.method == 'PUT');
    expect(put.headers.containsKey('if-match'), isFalse);
  });

  group('saved password', () {
    test('is kept for the same server and user', () async {
      await a.service.configure(
        serverUrl: davUrl(server),
        username: MockWebDav.username,
        remoteDir: 'Other/',
      );
      expect(a.credentials.password, MockWebDav.password);
    });

    test('is never reused for another host or user', () async {
      await expectLater(
        a.service.configure(
          serverUrl: 'https://other.example.com/dav/',
          username: MockWebDav.username,
          remoteDir: 'Tsumugi/',
        ),
        _syncError(SyncError.invalidConfig),
      );
      // 配置没有变。
      expect((await a.store.ensureState()).serverUrl, davUrl(server));
      await expectLater(
        a.service.configure(
          serverUrl: davUrl(server),
          username: 'bob',
          remoteDir: 'Tsumugi/',
        ),
        _syncError(SyncError.invalidConfig),
      );
      await a.service.configure(
        serverUrl: 'https://other.example.com/dav/',
        username: MockWebDav.username,
        remoteDir: 'Tsumugi/',
        password: 'new',
      );
      expect(a.credentials.password, 'new');
    });

    test('scope compares scheme, host, port and user', () {
      const saved = 'https://dav.example.com/a/';
      expect(
        sameCredentialScope(
          saved,
          'u',
          Uri.parse('https://DAV.example.com/b/'),
          'u',
        ),
        isTrue,
      );
      expect(
        sameCredentialScope(
          saved,
          'u',
          Uri.parse('https://dav.example.com:8443/'),
          'u',
        ),
        isFalse,
      );
      expect(
        sameCredentialScope(
          saved,
          'u',
          Uri.parse('https://evil.example.com/a/'),
          'u',
        ),
        isFalse,
      );
      expect(sameCredentialScope(null, 'u', Uri.parse(saved), 'u'), isFalse);
    });
  });

  test('a newer syncVersion is refused', () async {
    server.dav.collections.add('/Tsumugi/');
    server.dav.files[_remotePath] = (
      bytes: gzip.encode(utf8.encode('{"syncVersion": 2, "collections": {}}')),
      etag: '"v2"',
    );
    await expectLater(
      a.service.sync(),
      _syncError(SyncError.unsupportedVersion),
    );
    expect((await a.store.ensureState()).lastError, contains('更新'));
  });

  test('wrong password is reported as an auth error', () async {
    final c = TestDevice(server, password: 'wrong');
    addTearDown(c.close);
    await c.configure();
    await expectLater(c.service.sync(), _syncError(SyncError.auth));
  });

  group('repository subscriptions', () {
    Future<void> subscribe(TestDevice d, String url) => d.db
        .into(d.db.sourceRepositories)
        .insert(
          SourceRepositoriesCompanion.insert(
            url: url,
            name: '虚构仓库',
            addedAt: DateTime.utc(2026, 11, 19),
            indexJson: '{"name":"虚构仓库"}',
            indexSha256: 'abc',
          ),
        );

    Future<List<SourceRepositoryRow>> repos(TestDevice d) =>
        d.db.select(d.db.sourceRepositories).get();

    test(
      'subscriptions and unsubscriptions sync; the index does not',
      () async {
        await subscribe(a, 'https://repo.example.com/index.json');
        await a.service.sync();
        await b.service.sync();
        final row = (await repos(b)).single;
        expect(row.url, 'https://repo.example.com/index.json');
        // 名称与索引由 B 自己检查更新时取得。
        expect(row.indexJson, isEmpty);
        expect(
          row.addedAt.isAtSameMomentAs(DateTime.utc(2026, 11, 19)),
          isTrue,
        );
        expect(
          remoteDoc()
              .collections[SyncCollections.repositories]!
              .values
              .single
              .data,
          {'addedAt': DateTime.utc(2026, 11, 19).millisecondsSinceEpoch},
        );

        // B 检查更新刷新了名称与索引：不算同步改动。
        await (b.db.update(b.db.sourceRepositories)).write(
          const SourceRepositoriesCompanion(
            name: Value('新名称'),
            indexJson: Value('{}'),
          ),
        );
        expect(await b.store.hasLocalChanges(), isFalse);

        await a.db.delete(a.db.sourceRepositories).go();
        await a.service.sync();
        await b.service.sync();
        expect(await repos(b), isEmpty);
      },
    );

    test('non-https or non-normalized addresses are not applied', () async {
      await a.service.sync();
      final doc = remoteDoc();
      SyncRecord rec(String url) => SyncRecord(
        key: [url],
        modifiedAt: 1000,
        deviceId: 'zzzz',
        data: const {'addedAt': 0},
      );
      server.dav.files[_remotePath] = (
        bytes: SyncDocument(
          collections: {
            ...doc.collections,
            SyncCollections.repositories: {
              for (final u in [
                'http://repo.example.com/index.json',
                'https://repo.example.com/../index.json',
                'https://ok.example.com/index.json',
              ])
                rec(u).keyString: rec(u),
            },
          },
        ).encode(),
        etag: '"crafted"',
      );
      await b.service.sync();
      expect((await repos(b)).map((r) => r.url), [
        'https://ok.example.com/index.json',
      ]);
    });
  });

  group('sources', () {
    test(
      'new sources wait for confirmation; settings follow after install',
      () async {
        await a.registry.importText(_settingsManifest());
        await a.registry.setEnabled('com.example.settings', false);
        await a.registry.setSettings('com.example.settings', {
          'quality': 'low',
        });
        await a.service.sync();

        final summary = await b.service.sync();
        expect(summary.pendingSources, 1);
        expect(await b.registry.getAll(), isEmpty, reason: '不直接安装');
        final pending = decodePending(await b.store.ensureState());
        expect(pending.single.id, 'com.example.settings');
        expect(pending.single.isUpdate, isFalse);

        // 再同步一次，待安装项仍在，远端记录不被删除。
        await b.service.sync();
        expect(decodePending(await b.store.ensureState()), hasLength(1));
        expect(remoteDoc().collections[SyncCollections.sources], hasLength(1));

        final preview = await b.service.preparePending(pending.single);
        expect(preview.hosts, contains('example.com'));
        await b.service.installPending(pending.single, preview);
        final installed = (await b.registry.get('com.example.settings'))!;
        expect(installed.enabled, isFalse);
        expect(installed.settings['quality'], 'low');
        expect(decodePending(await b.store.ensureState()), isEmpty);

        // 装好后与远端一致：不再上传。
        expect((await b.service.sync()).uploaded, isFalse);
      },
    );

    test('enable state merges directly; changed manifests wait', () async {
      await a.registry.importText(_settingsManifest());
      await a.service.sync();
      await b.registry.importText(_settingsManifest());
      await b.service.sync();

      await a.registry.setEnabled('com.example.settings', false);
      await a.service.sync();
      await b.service.sync();
      expect((await b.registry.get('com.example.settings'))!.enabled, isFalse);

      // A 升级了清单（新增主机）：B 不自动安装，只合并启用状态。
      await a.registry.importText(
        _settingsManifest(
          version: '1.1.0',
          hosts: ['*.example.com', 'cdn.example.net'],
        ),
      );
      await a.registry.setEnabled('com.example.settings', true);
      await a.service.sync();
      await b.service.sync();
      final local = (await b.registry.get('com.example.settings'))!;
      expect(local.version, '1.0.0');
      expect(local.enabled, isTrue);
      final pending = decodePending(await b.store.ensureState()).single;
      expect(pending.isUpdate, isTrue);
      expect(pending.version, '1.1.0');

      // 再同步不会把旧清单写回远端。
      await b.service.sync();
      expect(
        remoteDoc()
            .collections[SyncCollections.sources]!
            .values
            .single
            .data!['manifest'],
        contains('1.1.0'),
      );
    });

    test(
      'an older device toggling a source does not downgrade the manifest',
      () async {
        await a.registry.importText(_settingsManifest());
        await a.service.sync();
        await b.registry.importText(_settingsManifest());
        await b.service.sync();
        await a.registry.importText(_settingsManifest(version: '1.1.0'));
        await a.service.sync();
        // B 还没装 1.1.0，就改了启用状态（之后的 modifiedAt 更大）。
        await Future<void>.delayed(const Duration(milliseconds: 3));
        await b.registry.setEnabled('com.example.settings', false);
        await b.service.sync();
        final record =
            remoteDoc().collections[SyncCollections.sources]!.values.single;
        expect(record.data!['manifest'], contains('1.1.0'));
        expect(record.data!['enabled'], isFalse);
        final pending = decodePending(await b.store.ensureState()).single;
        expect(pending.version, '1.1.0');
        // A 照常得到 B 的启用状态，不出现待安装项。
        await a.service.sync();
        expect(
          (await a.registry.get('com.example.settings'))!.enabled,
          isFalse,
        );
        expect(decodePending(await a.store.ensureState()), isEmpty);
      },
    );

    test(
      'sources installed from sync are recorded as local, not repository',
      () async {
        await a.registry.importText(
          _settingsManifest(),
          origin: const SourceOrigin.repository(
            'https://repo.example.com/sources/settings.json',
            repositoryUrl: 'https://repo.example.com/index.json',
          ),
        );
        await a.service.sync();
        await b.service.sync();
        final pending = decodePending(await b.store.ensureState()).single;
        expect(
          pending.originUrl,
          'https://repo.example.com/sources/settings.json',
        );
        final preview = await b.service.preparePending(pending);
        await b.service.installPending(pending, preview);
        final installed = (await b.registry.get('com.example.settings'))!;
        expect(installed.origin, const SourceOrigin.local(syncOriginLabel));
        expect(installed.origin.repositoryUrl, isNull);
      },
    );

    test('uninstalled elsewhere: removed locally', () async {
      await a.registry.importText(_settingsManifest());
      await a.service.sync();
      await b.registry.importText(_settingsManifest());
      await b.service.sync();
      await a.registry.remove('com.example.settings');
      await a.service.sync();
      await b.service.sync();
      expect(await b.registry.getAll(), isEmpty);
    });

    test(
      'dismissed pending sources stay hidden until the record changes',
      () async {
        await a.registry.importText(_settingsManifest());
        await a.service.sync();
        await b.service.sync();
        final pending = decodePending(await b.store.ensureState()).single;
        await b.service.dismissPending(pending);
        await b.service.sync();
        expect(
          decodePending(await b.store.ensureState()).single.dismissed,
          isTrue,
        );

        await a.registry.setEnabled('com.example.settings', false);
        await a.service.sync();
        await b.service.sync();
        expect(
          decodePending(await b.store.ensureState()).single.dismissed,
          isFalse,
        );
      },
    );
  });
}
