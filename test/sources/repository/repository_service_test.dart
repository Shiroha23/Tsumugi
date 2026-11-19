import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/storage/app_database.dart';
import 'package:tsumugi/sources/registry/providers.dart';
import 'package:tsumugi/sources/repository/providers.dart';

import '../../../tool/mock_server/mock_server.dart';
import '../../core/storage/test_database.dart';

Matcher _throwsKind(RepositoryErrorKind kind) =>
    throwsA(isA<RepositoryException>().having((e) => e.kind, 'kind', kind));

void main() {
  late MockServer server;
  late AppDatabase db;
  late SourceRegistry registry;
  late RepositoryHttpClient http;
  late RepositoryService service;
  var now = DateTime.utc(2026, 11, 19);

  setUpAll(() async => server = await MockServer.start());
  tearDownAll(() => server.close());
  setUp(() {
    server.liveRepository = MockServer.defaultLiveRepository;
    now = DateTime.utc(2026, 11, 19);
    db = openTestDatabase();
    registry = SourceRegistry(db);
    http = RepositoryHttpClient(
      timeout: const Duration(seconds: 5),
      allowLoopbackHttp: true,
    );
    service = RepositoryService(db, registry, http, clock: () => now);
  });
  tearDown(() async {
    http.close();
    await db.close();
  });

  String repoUrl(String dir) =>
      'http://127.0.0.1:${server.port}/repo/$dir/index.json';

  Future<SubscribedRepository> subscribe(String dir) async =>
      service.subscribe(await service.fetchIndex(repoUrl(dir)));

  RepositoryEntry entry(SubscribedRepository repo, String id) =>
      repo.index!.entry(id)!;

  group('订阅', () {
    test('取索引 → 订阅 → 列表；重复订阅被拒绝', () async {
      final index = await service.fetchIndex(repoUrl('good'));
      expect(index.name, '测试仓库');
      expect(index.entries, hasLength(7));
      expect(await service.getAll(), isEmpty, reason: 'fetchIndex 不写数据库');

      final repo = await service.subscribe(index);
      expect(repo.url, repoUrl('good'));
      expect(repo.name, '测试仓库');
      expect(repo.lastCheckedAt!.toUtc(), now);
      expect(repo.lastError, isNull);
      expect(repo.entries, hasLength(7));
      expect((await service.getAll()).single.url, repo.url);

      await expectLater(
        service.fetchIndex(repoUrl('good')),
        _throwsKind(RepositoryErrorKind.alreadySubscribed),
      );
    });

    test('repoVersion 过高、id 重复的仓库无法订阅', () async {
      await expectLater(
        service.fetchIndex(repoUrl('future')),
        _throwsKind(RepositoryErrorKind.unsupportedRepoVersion),
      );
      await expectLater(
        service.fetchIndex(repoUrl('dup')),
        _throwsKind(RepositoryErrorKind.invalidIndex),
      );
    });

    test('索引超过 2 MiB 被拒绝', () async {
      await expectLater(
        service.fetchIndex(
          'http://127.0.0.1:${server.port}/large?bytes=${2 * 1024 * 1024 + 1}',
        ),
        _throwsKind(RepositoryErrorKind.tooLarge),
      );
    });

    test('退订后已装的源保留，显示“仓库已移除”', () async {
      final repo = await subscribe('good');
      await registry.install(
        await service.prepareInstall(
          repo,
          entry(repo, 'com.example.repo.comic'),
        ),
      );
      expect(await service.unsubscribe(repo.url), isTrue);
      expect(await service.getAll(), isEmpty);
      final installed = await registry.getAll();
      expect(installed.single.id, 'com.example.repo.comic');
      expect(
        sourceRepositoryStatuses(installed, const [])['com.example.repo.comic'],
        isA<SourceRepositoryRemoved>(),
      );
    });
  });

  group('检查更新', () {
    test('失败时记录错误并保留上次的索引；成功后清除错误', () async {
      final repo = await subscribe('live');
      server.liveRepository = 'missing';
      now = DateTime.utc(2026, 11, 20);
      final error = await service.refresh(repo.url);
      expect(error!.kind, RepositoryErrorKind.http);
      var saved = (await service.get(repo.url))!;
      expect(saved.lastCheckedAt!.toUtc(), now);
      expect(saved.lastError, RepositoryErrorKind.http);
      expect(saved.lastErrorMessage, contains('404'));
      expect(saved.entries.single.version, '1.0.0', reason: '保留离线可浏览的索引');

      server.liveRepository = 'flow-v2';
      expect(await service.refresh(repo.url), isNull);
      saved = (await service.get(repo.url))!;
      expect(saved.lastError, isNull);
      expect(saved.lastErrorMessage, isNull);
      expect(saved.entries.single.version, '1.1.0');
    });

    test('refreshAll 串行检查全部仓库，单个失败不影响其他', () async {
      final good = await subscribe('good');
      final live = await subscribe('live');
      server.liveRepository = 'missing';
      server.requests.clear();
      await service.refreshAll();
      expect(server.requests.map((r) => r.path), [
        '/repo/good/index.json',
        '/repo/live/index.json',
      ]);
      expect((await service.get(good.url))!.lastError, isNull);
      expect(
        (await service.get(live.url))!.lastError,
        RepositoryErrorKind.http,
      );
    });

    test('同时调用 refreshAll 只检查一轮', () async {
      await subscribe('good');
      server.requests.clear();
      await Future.wait([service.refreshAll(), service.refreshAll()]);
      expect(server.hits('/repo/good/index.json'), 1);
    });

    test('只对来自本仓库的源提示可更新', () async {
      final repo = await subscribe('live');
      await registry.install(
        await service.prepareInstall(
          repo,
          entry(repo, 'com.example.repo.flow'),
        ),
      );
      expect(
        sourceRepositoryStatuses(
          await registry.getAll(),
          await service.getAll(),
        ),
        isEmpty,
      );
      server.liveRepository = 'flow-v2';
      await service.refreshAll();
      final statuses = sourceRepositoryStatuses(
        await registry.getAll(),
        await service.getAll(),
      );
      final update = statuses['com.example.repo.flow'] as SourceUpdateAvailable;
      expect(update.entry.version, '1.1.0');
      expect(update.repository.url, repo.url);
      expect(
        (await registry.get('com.example.repo.flow'))!.version,
        '1.0.0',
        reason: '只提示，不自动安装',
      );
    });
  });

  group('安装 / 更新', () {
    test('安装：记录清单地址与所属仓库', () async {
      final repo = await subscribe('good');
      final e = entry(repo, 'com.example.repo.comic');
      final preview = await service.prepareInstall(repo, e);
      expect(preview.action, ImportAction.install);
      expect(preview.hosts, ['comic.example.com', 'img.example.com']);
      expect(preview.newHosts, isEmpty);
      final s = await registry.install(preview);
      expect(s.origin.kind, SourceOriginKind.repository);
      expect(s.origin.label, e.url.toString());
      expect(s.origin.repositoryUrl, repo.url);
      expect(s.manifestSha256, e.sha256);
      expect(entryState(repo.url, e, s), RepositoryEntryState.installed);
    });

    test('sha256 不符：拒绝', () async {
      final repo = await subscribe('good');
      await expectLater(
        service.prepareInstall(repo, entry(repo, 'com.example.repo.badhash')),
        _throwsKind(RepositoryErrorKind.hashMismatch),
      );
    });

    test('清单 version 与索引不一致：拒绝', () async {
      final repo = await subscribe('good');
      await expectLater(
        service.prepareInstall(repo, entry(repo, 'com.example.repo.mismatch')),
        _throwsKind(RepositoryErrorKind.manifestMismatch),
      );
    });

    test('apiVersion 过高：不下载，提示更新客户端', () async {
      final repo = await subscribe('good');
      final e = entry(repo, 'com.example.repo.future');
      expect(
        entryState(repo.url, e, null),
        RepositoryEntryState.needsClientUpdate,
      );
      server.requests.clear();
      await expectLater(
        service.prepareInstall(repo, e),
        _throwsKind(RepositoryErrorKind.unsupportedApiVersion),
      );
      expect(server.requests, isEmpty);
    });

    test('清单重定向到 http：拒绝', () async {
      final repo = await subscribe('good');
      await expectLater(
        service.prepareInstall(repo, entry(repo, 'com.example.repo.insecure')),
        _throwsKind(RepositoryErrorKind.insecureUrl),
      );
    });

    test('清单超过 4 MiB：拒绝', () async {
      final repo = await subscribe('good');
      await expectLater(
        service.prepareInstall(repo, entry(repo, 'com.example.repo.large')),
        _throwsKind(RepositoryErrorKind.tooLarge),
      );
    });

    test('同 id 的本地导入源不能被仓库安装或更新', () async {
      final repo = await subscribe('good');
      final text = File('test/fixtures/repository/good/sources/comic.json')
          .readAsStringSync()
          .replaceFirst('"1.0.0"', '"0.9.0"');
      await registry.importText(text);
      final e = entry(repo, 'com.example.repo.comic');
      expect(
        entryState(repo.url, e, await registry.get(e.id)),
        RepositoryEntryState.otherOrigin,
      );
      server.requests.clear();
      await expectLater(
        service.prepareInstall(repo, e),
        _throwsKind(RepositoryErrorKind.otherOrigin),
      );
      expect(server.requests, isEmpty);
      expect(
        sourceRepositoryStatuses(
          await registry.getAll(),
          await service.getAll(),
        ),
        isEmpty,
      );
    });

    test('来自其他仓库的同 id 源不能被本仓库更新（含预览后才变化的情况）', () async {
      final live = await subscribe('live');
      server.liveRepository = 'flow-v2';
      // 以 flow-v1 作为“另一个仓库”。
      final other = await subscribe('flow-v1');
      final preview = await service.prepareInstall(
        live,
        (await service.fetchIndexFor(live)).entry('com.example.repo.flow')!,
      );
      // 预览之后，用户从另一个仓库装了同 id 的源。
      await registry.install(
        await service.prepareInstall(
          other,
          entry(other, 'com.example.repo.flow'),
        ),
      );
      await expectLater(
        registry.install(preview),
        throwsA(
          isA<SourceImportException>().having(
            (e) => e.error,
            'error',
            SourceImportError.otherOrigin,
          ),
        ),
      );
      expect((await registry.get('com.example.repo.flow'))!.version, '1.0.0');
    });

    test('更新：列出新增主机；不允许降级', () async {
      final repo = await subscribe('live');
      await registry.install(
        await service.prepareInstall(
          repo,
          entry(repo, 'com.example.repo.flow'),
        ),
      );
      server.liveRepository = 'flow-v2';
      await service.refresh(repo.url);
      final updated = (await service.get(repo.url))!;
      final preview = await service.prepareInstall(
        updated,
        entry(updated, 'com.example.repo.flow'),
      );
      expect(preview.action, ImportAction.upgrade);
      expect(preview.newHosts, ['cdn.example.org']);
      final s = await registry.install(preview);
      expect(s.version, '1.1.0');
      expect(s.origin.repositoryUrl, repo.url);

      // 仓库回退到旧版本：不提示，也不能安装。
      server.liveRepository = 'flow-v1';
      await service.refresh(repo.url);
      final rolledBack = (await service.get(repo.url))!;
      final old = entry(rolledBack, 'com.example.repo.flow');
      expect(
        entryState(repo.url, old, await registry.get(old.id)),
        RepositoryEntryState.installed,
      );
      await expectLater(
        service.prepareInstall(rolledBack, old),
        throwsA(
          isA<SourceImportException>().having(
            (e) => e.error,
            'error',
            SourceImportError.downgrade,
          ),
        ),
      );
    });
  });
}

extension on RepositoryService {
  /// 重新取 [repo] 的索引（不写数据库）。
  Future<RepositoryIndex> fetchIndexFor(SubscribedRepository repo) async {
    await refresh(repo.url);
    return (await get(repo.url))!.index!;
  }
}
