import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/storage/app_database.dart';
import 'package:tsumugi/features/explore/explore_controller.dart';
import 'package:tsumugi/features/explore/explore_preferences.dart';
import 'package:tsumugi/sources/model/manifest.dart';
import 'package:tsumugi/sources/registry/providers.dart';
import 'package:tsumugi/sources/source_call.dart';

import '../../core/network/mock_support.dart';
import '../../core/storage/test_database.dart';
import '../../sources/runtime/runtime_support.dart';

const _declarative = 'com.example.mock.comic.declarative';
const _script = 'com.example.mock.comic.script';

SourceManifest _manifest(String json) =>
    SourceManifest.fromJson(jsonDecode(json) as Map<String, dynamic>);

void main() {
  group('supportsExplore', () {
    test('声明式看 rules.explore；脚本看是否出现 explore', () {
      expect(supportsExplore(_manifest(mockSourceJson('declarative'))), isTrue);
      expect(supportsExplore(_manifest(mockSourceJson('script'))), isTrue);
      expect(supportsExplore(_manifest(fakeManifestJson('x'))), isFalse);
      expect(
        supportsExplore(
          _manifest(mockSourceJson('script')).copyWith(
            script:
                'export async function search() { return {}; }\n'
                'export async function exploreList() {}',
          ),
        ),
        isFalse,
      );
      expect(
        supportsExplore(
          _manifest(mockSourceJson('declarative'))
              .copyWith(rules: {'explore': <Object?>[]}),
        ),
        isFalse,
      );
    });
  });

  late MockServer server;
  late AppDatabase db;
  late SourceRegistry registry;
  late ProviderContainer container;
  late MemoryExplorePreferencesStore prefs;

  setUp(() async {
    server = await MockServer.start();
    db = openTestDatabase();
    registry = SourceRegistry(db);
    prefs = MemoryExplorePreferencesStore();
    container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        sourceFactoriesProvider.overrideWithValue(mockFactories(server)),
        explorePreferencesStoreProvider.overrideWithValue(prefs),
      ],
    );
    // 保持 autoDispose 的控制器在整个测试中存活。
    container.listen(exploreControllerProvider, (_, _) {});
  });
  tearDown(() async {
    container.dispose();
    await db.close();
    await server.close();
  });

  /// 等到控制器状态满足 [done]。
  Future<ExploreState> until(bool Function(ExploreState s) done) {
    final completer = Completer<ExploreState>();
    final sub = container.listen(exploreControllerProvider, (_, next) {
      if (!completer.isCompleted && done(next)) completer.complete(next);
    }, fireImmediately: true);
    return completer.future
        .timeout(const Duration(seconds: 20))
        .whenComplete(sub.close);
  }

  ExploreController notifier() =>
      container.read(exploreControllerProvider.notifier);

  bool loaded(ExploreState s) =>
      s.categories?.hasValue == true && !s.feed.loading && s.feed.page > 0;

  for (final (engine, id, latest, rank) in [
    ('declarative', _declarative, '0', '1'),
    ('script', _script, 'latest', 'rank'),
  ]) {
    test('$engine 源：分类、翻页、切换分类（mock 服务器）', () async {
      await registry.importText(mockSourceJson(engine));
      // 不提供发现页的源不会被选中。
      await registry.importText(fakeManifestJson('com.example.plain'));

      var s = await until((s) => s.source != null && loaded(s));
      expect(s.source!.id, id);
      expect(s.categories!.value!.map((c) => (c.id, c.name)), [
        (latest, '最新'),
        (rank, '排行'),
      ]);
      expect(s.categoryId, latest);
      expect(s.feed.items.map((i) => i.title), ['星之栖处', '雨夜纸鹤']);
      expect(s.feed.items.first.subtitle, '虚构作者甲');
      expect(s.feed.hasMore, isTrue);

      await notifier().loadMore();
      s = container.read(exploreControllerProvider);
      expect(s.feed.items.map((i) => i.title), ['星之栖处', '雨夜纸鹤', '灯塔与猫']);
      expect(s.feed.page, 2);
      expect(s.feed.hasMore, isFalse);

      await notifier().selectCategory(rank);
      s = container.read(exploreControllerProvider);
      expect(s.feed.items.map((i) => i.title), ['月下书店']);
      expect(s.feed.hasMore, isFalse);
      expect(prefs.value, ExploreSelection(sourceId: id, categoryId: rank));
      expect(server.hits('/comic/explore/latest'), 2);
      expect(server.hits('/comic/explore/rank'), 1);
    });
  }

  test('两个源之间切换，未知分类的 404 显示为出错', () async {
    await registry.importText(mockSourceJson('declarative'));
    await registry.importText(mockSourceJson('script'));
    await until((s) => s.source?.id == _declarative && loaded(s));

    await notifier().selectSource(_script);
    var s = container.read(exploreControllerProvider);
    expect(s.source!.id, _script);
    expect(s.feed.items, hasLength(2));

    // 脚本源的 exploreList 可以接受任意分类 id；这里直接构造一个服务器不认识的分类。
    final broken = _manifest(mockSourceJson('script'));
    await registry.importText(
      jsonEncode({
        ...broken.toJson(),
        'id': 'com.example.mock.comic.broken',
        'name': '坏分类',
        'script': broken.script!.replaceFirst(
          "{ name: '最新', id: 'latest' }",
          "{ name: '不存在', id: 'missing' }",
        ),
      }),
    );
    // 等控制器看到新安装的源。
    while (container
            .read(exploreSourcesProvider)
            .value
            ?.any((s) => s.id == 'com.example.mock.comic.broken') !=
        true) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await notifier().selectSource('com.example.mock.comic.broken');
    s = container.read(exploreControllerProvider);
    expect(s.categoryId, 'missing');
    expect(s.feed.items, isEmpty);
    expect(s.feed.error, isNotNull);
  });

  test('界面超时（#65）：验证页等待不计时；超时取消底层调用', () async {
    container.dispose();
    final ui = DelayedScriptUi(const Duration(milliseconds: 900));
    container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        sourceFactoriesProvider.overrideWithValue(
          mockFactories(server, ui: ui),
        ),
        explorePreferencesStoreProvider.overrideWithValue(prefs),
        exploreTimeoutProvider.overrideWithValue(
          const Duration(milliseconds: 400),
        ),
      ],
    );
    container.listen(exploreControllerProvider, (_, _) {});
    await registry.importText(callControlSourceJson());

    // 第一个分类需要打开验证页（900 ms > 界面超时 400 ms）。
    var s = await until(
      (s) =>
          s.categories?.hasValue == true &&
          !s.feed.loading &&
          (s.feed.page > 0 || s.feed.error != null),
    );
    expect(s.feed.error, isNull);
    expect(s.feed.items.single.title, 'verify');

    await notifier().selectCategory('slow:3000');
    s = container.read(exploreControllerProvider);
    expect(s.feed.error, isA<SourceCallTimeoutException>());

    final sw = Stopwatch()..start();
    await notifier().selectCategory('fast');
    s = container.read(exploreControllerProvider);
    expect(s.feed.items.single.title, 'fast');
    expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
  });
}
