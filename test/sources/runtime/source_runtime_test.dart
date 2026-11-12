import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/storage/app_database.dart';
import 'package:tsumugi/sources/model/common.dart';
import 'package:tsumugi/sources/registry/providers.dart';
import 'package:tsumugi/sources/runtime/source_error_text.dart';
import 'package:tsumugi/sources/runtime/source_runtime.dart';
import 'package:tsumugi/sources/source.dart';

import '../../core/network/mock_support.dart';
import '../../core/storage/test_database.dart';
import 'runtime_support.dart';

void main() {
  late AppDatabase db;
  late SourceRegistry registry;

  setUp(() {
    db = openTestDatabase();
    registry = SourceRegistry(db);
  });
  tearDown(() => db.close());

  group('sourceInstanceProvider (fake factory)', () {
    late FakeFactory factory;
    late ProviderContainer container;

    setUp(() {
      factory = FakeFactory();
      container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          sourceFactoriesProvider.overrideWithValue(SourceFactories([factory])),
        ],
      );
      addTearDown(container.dispose);
    });

    Future<Source> read(String id) =>
        container.read(sourceRuntimeProvider).get(id);

    /// 等数据库变化传到 provider。
    Future<void> settle() =>
        Future<void>.delayed(const Duration(milliseconds: 50));

    test('缓存实例；禁用时释放并失败，重新启用后重建', () async {
      await registry.importText(fakeManifestJson('com.example.a'));
      final first = await read('com.example.a');
      expect(await read('com.example.a'), same(first));
      expect(factory.created, hasLength(1));

      await registry.setEnabled('com.example.a', false);
      await settle();
      expect((first as FakeSource).disposed, isTrue);
      await expectLater(
        read('com.example.a'),
        throwsA(isA<SourceUnavailableException>()),
      );

      await registry.setEnabled('com.example.a', true);
      await settle();
      final second = await read('com.example.a');
      expect(second, isNot(same(first)));
      expect(factory.created, hasLength(2));
    });

    test('无关的数据库变化不会重建实例', () async {
      await registry.importText(fakeManifestJson('com.example.a'));
      await registry.importText(fakeManifestJson('com.example.b'));
      final a = await read('com.example.a');
      await registry.reorder(['com.example.b', 'com.example.a']);
      await registry.setEnabled('com.example.b', false);
      await settle();
      expect(await read('com.example.a'), same(a));
      expect((a as FakeSource).disposed, isFalse);
    });

    test('升级后用新清单重建', () async {
      await registry.importText(fakeManifestJson('com.example.a'));
      final old = await read('com.example.a');
      await registry.importText(
        fakeManifestJson('com.example.a', version: '1.1.0', name: '新名字'),
      );
      await settle();
      expect((old as FakeSource).disposed, isTrue);
      final upgraded = await read('com.example.a');
      expect(upgraded.manifest.version, '1.1.0');
    });

    test('删除后释放并报告未安装', () async {
      await registry.importText(fakeManifestJson('com.example.a'));
      final s = await read('com.example.a');
      await registry.remove('com.example.a');
      await settle();
      expect((s as FakeSource).disposed, isTrue);
      final error = await read('com.example.a')
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect(error, isA<SourceUnavailableException>());
      expect(describeSourceError(error!).title, '源未安装或已被删除');
    });

    test('创建失败不缓存，下次重试', () async {
      var fail = true;
      final flaky = FakeFactory((m) {
        if (fail) throw const SourceException(SourceErrorCode.parse, 'bad');
        return FakeSource(m);
      });
      final c = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          sourceFactoriesProvider.overrideWithValue(SourceFactories([flaky])),
        ],
      );
      addTearDown(c.dispose);
      await registry.importText(fakeManifestJson('com.example.a'));
      final runtime = c.read(sourceRuntimeProvider);
      await expectLater(
        runtime.get('com.example.a'),
        throwsA(isA<SourceException>()),
      );
      fail = false;
      expect(await runtime.get('com.example.a'), isA<FakeSource>());
    });

    test('sourceInstanceProvider 在源变化时失效并重新获取', () async {
      await registry.importText(fakeManifestJson('com.example.a'));
      final sub = container.listen(
        sourceInstanceProvider('com.example.a'),
        (_, _) {},
      );
      addTearDown(sub.close);
      final first = await container.read(
        sourceInstanceProvider('com.example.a').future,
      );
      await registry.importText(
        fakeManifestJson('com.example.a', version: '2.0.0'),
      );
      await settle();
      final second = await container.read(
        sourceInstanceProvider('com.example.a').future,
      );
      expect(second, isNot(same(first)));
      expect(second.manifest.version, '2.0.0');
    });

    test('容器销毁时释放实例', () async {
      await registry.importText(fakeManifestJson('com.example.a'));
      final s = await read('com.example.a') as FakeSource;
      container.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(s.disposed, isTrue);
    });
  });

  group('真实工厂 + mock 服务器', () {
    late MockServer server;
    late ProviderContainer container;

    setUp(() async {
      server = await MockServer.start();
      container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          sourceFactoriesProvider.overrideWithValue(mockFactories(server)),
        ],
      );
    });
    tearDown(() async {
      container.dispose();
      await server.close();
    });

    for (final engine in ['declarative', 'script']) {
      test('$engine：搜索、分页与详情', () async {
        final installed = await registry.importText(mockSourceJson(engine));
        final source = await container
            .read(sourceRuntimeProvider)
            .get(installed.id);

        final page1 = await source.search('星', 1);
        expect(page1.items.map((i) => i.title), ['星之栖处', '雨夜纸鹤']);
        expect(page1.items.first.id, '/comic/book/1');
        expect(page1.items.first.cover, 'http://img.example.com/covers/1.png');
        expect(page1.hasMore, isTrue);
        final page2 = await source.search('星', 2);
        expect(page2.items.map((i) => i.title), ['灯塔与猫']);
        expect(page2.hasMore, isFalse);

        final detail = await source.detail('/comic/book/1');
        expect(detail.title, '星之栖处');
        expect(detail.author, '虚构作者甲');
        expect(detail.tags, ['奇幻', '日常']);
        expect(detail.units.map((u) => u.title), [
          '第 1 话 落脚点',
          '第 2 话 木板与钉子',
          '第 3 话 流星雨',
        ]);
      });
    }

    test('声明式源：网络层错误码透传（E_CHALLENGE）', () async {
      final installed = await registry.importText(
        mockSourceJson('declarative', {
          'id': 'com.example.mock.challenge',
          'rules': {
            'search': {
              'request': {'url': '/challenge'},
              'list': 'css:li',
              'fields': {'id': 'css:a@href', 'title': 'css:a@text'},
            },
          },
        }),
      );
      final source = await container
          .read(sourceRuntimeProvider)
          .get(installed.id);
      await expectLater(
        source.search('x', 1),
        throwsA(
          isA<SourceException>().having(
            (e) => e.code,
            'code',
            SourceErrorCode.challenge,
          ),
        ),
      );
    });
  });

  test('默认注册的工厂（无 mock 适配器）直连本地 mock 服务器', () async {
    final server = await MockServer.start();
    final container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );
    addTearDown(() async {
      container.dispose();
      await server.close();
    });
    final base = 'http://127.0.0.1:${server.port}';
    for (final engine in ['declarative', 'script']) {
      final installed = await registry.importText(
        mockSourceJson(engine, {'baseUrl': base}),
      );
      final source = await container
          .read(sourceRuntimeProvider)
          .get(installed.id);
      final page = await source.search('星', 1);
      expect(page.items, hasLength(2), reason: engine);
      final detail = await source.detail(page.items.first.id);
      expect(detail.units, hasLength(3), reason: engine);
    }
  });

  test('describeSourceError：§6 错误码的中文提示', () {
    expect(
      describeSourceError(const SourceException(SourceErrorCode.http, 'x', 503))
          .title,
      '服务器返回错误（HTTP 503）',
    );
    final challenge = describeSourceError(
      const SourceException(SourceErrorCode.challenge),
    );
    expect(challenge.title, '需要验证');
    expect(challenge.needsVerification, isTrue);
    final login = describeSourceError(
      const SourceException(SourceErrorCode.loginRequired),
    );
    expect(login.title, '需要登录');
    expect(login.needsVerification, isTrue);
    expect(
      describeSourceError(const SourceException(SourceErrorCode.network))
          .needsVerification,
      isFalse,
    );
    expect(
      describeSourceError(const SourceException(SourceErrorCode.network)).title,
      '网络错误或超时',
    );
    expect(describeSourceError(MediaType.comic).title, '未知错误');
  });
}
