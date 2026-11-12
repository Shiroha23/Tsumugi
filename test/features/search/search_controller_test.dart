import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/storage/app_database.dart';
import 'package:tsumugi/features/search/search_controller.dart';
import 'package:tsumugi/sources/model/common.dart';
import 'package:tsumugi/sources/registry/providers.dart';
import 'package:tsumugi/sources/source.dart';

import '../../core/network/mock_support.dart';
import '../../core/storage/test_database.dart';
import '../../sources/runtime/runtime_support.dart';

const _declarative = 'com.example.mock.comic.declarative';
const _script = 'com.example.mock.comic.script';

/// 搜索请求指向 mock 服务器 [url] 的声明式源。
String _declarativeAt(String id, String name, String url) =>
    mockSourceJson('declarative', {
      'id': id,
      'name': name,
      'rules': {
        'search': {
          'request': {'url': url},
          'list': 'css:.result-item',
          'fields': {'id': 'css:a@href', 'title': 'css:.title@text'},
        },
      },
    });

void main() {
  late MockServer server;
  late AppDatabase db;
  late SourceRegistry registry;
  late ProviderContainer container;

  setUp(() async {
    server = await MockServer.start();
    db = openTestDatabase();
    registry = SourceRegistry(db);
  });
  tearDown(() async {
    container.dispose();
    await db.close();
    await server.close();
  });

  ProviderContainer makeContainer({Duration? timeout}) =>
      container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          sourceFactoriesProvider.overrideWithValue(mockFactories(server)),
          if (timeout != null) searchTimeoutProvider.overrideWithValue(timeout),
        ],
      );

  /// 订阅控制器（保持 autoDispose provider 存活），记录每一次状态。
  (SourceSearchController, List<SearchState>) controller() {
    final states = <SearchState>[];
    container.listen(
      sourceSearchControllerProvider,
      (_, next) => states.add(next),
      fireImmediately: true,
    );
    return (container.read(sourceSearchControllerProvider.notifier), states);
  }

  SourceSearchGroup group(String id) => container
      .read(sourceSearchControllerProvider)
      .groups
      .singleWhere((g) => g.sourceId == id);

  test('并发搜索所有已启用源，结果按源分组；单源失败只影响自己的分组', () async {
    await registry.importText(mockSourceJson('declarative'));
    await registry.importText(mockSourceJson('script'));
    await registry.importText(
      _declarativeAt('com.example.mock.challenge', '验证源', '/challenge'),
    );
    await registry.importText(
      _declarativeAt('com.example.mock.broken', '坏源', '/status/500'),
    );
    await registry.importText(
      _declarativeAt('com.example.mock.slow', '慢源', '/slow?ms=1500'),
    );
    final disabled = await registry.importText(
      _declarativeAt('com.example.mock.disabled', '禁用源', '/status/404'),
    );
    await registry.setEnabled(disabled.id, false);
    makeContainer();
    final (search, states) = controller();

    await search.search('  星  ');

    final state = container.read(sourceSearchControllerProvider);
    expect(state.keyword, '星');
    expect(state.groups.map((g) => g.sourceName), [
      'Mock 漫画（声明式）',
      'Mock 漫画（脚本）',
      '验证源',
      '坏源',
      '慢源',
    ]);
    for (final id in [_declarative, _script]) {
      final g = group(id);
      expect(g.error, isNull);
      expect(g.items.map((i) => i.title), ['星之栖处', '雨夜纸鹤']);
      expect(g.hasMore, isTrue);
      expect(g.page, 1);
    }
    expect(
      group('com.example.mock.challenge').error,
      isA<SourceException>().having(
        (e) => e.code,
        'code',
        SourceErrorCode.challenge,
      ),
    );
    expect(
      group('com.example.mock.broken').error,
      isA<SourceException>()
          .having((e) => e.code, 'code', SourceErrorCode.http)
          .having((e) => e.status, 'status', 500),
    );
    expect(group('com.example.mock.slow').loading, isFalse);
    // 禁用源没有被请求。
    expect(server.hits('/status/404'), 0);

    // 流式：快的源先出结果，慢源仍在加载。
    expect(
      states.any((s) {
        final byId = {for (final g in s.groups) g.sourceId: g};
        return byId[_declarative]?.items.isNotEmpty == true &&
            byId[_script]?.items.isNotEmpty == true &&
            byId['com.example.mock.slow']?.loading == true;
      }),
      isTrue,
    );
  });

  test('加载下一页直到 hasMore 为 false', () async {
    await registry.importText(mockSourceJson('declarative'));
    await registry.importText(mockSourceJson('script'));
    makeContainer();
    final (search, _) = controller();
    await search.search('星');

    await Future.wait([
      search.loadMore(_declarative),
      search.loadMore(_script),
    ]);
    for (final id in [_declarative, _script]) {
      final g = group(id);
      expect(g.items.map((i) => i.title), ['星之栖处', '雨夜纸鹤', '灯塔与猫']);
      expect(g.page, 2);
      expect(g.hasMore, isFalse);
    }

    // 没有更多时不再请求。
    final before = server.hits('/comic/search');
    await search.loadMore(_declarative);
    expect(server.hits('/comic/search'), before);
  });

  test('新搜索读取注册表期间，旧分组不能发起分页请求', () async {
    await registry.importText(mockSourceJson('declarative'));
    makeContainer();
    final (search, _) = controller();
    await search.search('星');
    expect(group(_declarative).hasMore, isTrue);

    final pending = search.search('雨');
    // 新搜索还在等注册表，旧分组仍然显示着「加载更多」。
    await search.loadMore(_declarative);
    await pending;

    final g = group(_declarative);
    expect(container.read(sourceSearchControllerProvider).keyword, '雨');
    expect(g.page, 1);
    expect(g.items, hasLength(2));
    expect(
      server.requests
          .where((r) => r.path == '/comic/search')
          .map((r) => r.query['q']),
      ['星', '雨'],
    );
  });

  test('单源超时只在该分组显示错误', () async {
    await registry.importText(mockSourceJson('declarative'));
    await registry.importText(
      _declarativeAt('com.example.mock.slow', '慢源', '/slow?ms=3000'),
    );
    makeContainer(timeout: const Duration(milliseconds: 500));
    final (search, _) = controller();
    await search.search('星');

    expect(group(_declarative).items, hasLength(2));
    expect(group('com.example.mock.slow').error, isA<TimeoutException>());
  });

  test('失败后重试同一页', () async {
    // 前 3 次（首次 + 网络层自动重试 2 次）返回 503，之后 200。
    await registry.importText(
      _declarativeAt(
        'com.example.mock.flaky',
        '不稳定源',
        '/flaky?key=search&fail=3&status=503',
      ),
    );
    makeContainer();
    final (search, _) = controller();
    await search.search('星');
    final failed = group('com.example.mock.flaky');
    expect(failed.error, isA<SourceException>());
    expect(failed.page, 0);

    await search.loadMore('com.example.mock.flaky');
    final ok = group('com.example.mock.flaky');
    expect(ok.error, isNull);
    expect(ok.page, 1);
    expect(server.hits('/flaky'), 4);
  });

  test('按类型筛选；新搜索覆盖旧结果', () async {
    await registry.importText(mockSourceJson('declarative'));
    makeContainer();
    final (search, _) = controller();

    await search.setType(MediaType.novel);
    await search.search('星');
    final novel = container.read(sourceSearchControllerProvider);
    expect(novel.started, isTrue);
    expect(novel.groups, isEmpty);

    await search.setType(MediaType.comic);
    final comic = container.read(sourceSearchControllerProvider);
    expect(comic.type, MediaType.comic);
    expect(comic.groups.single.items, hasLength(2));
  });
}
