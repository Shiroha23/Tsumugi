import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/engine/script/script_runtime.dart';
import 'package:tsumugi/core/storage/app_database.dart';
import 'package:tsumugi/core/storage/source_storage.dart';
import 'package:tsumugi/sources/model/common.dart';
import 'package:tsumugi/sources/model/content.dart';
import 'package:tsumugi/sources/model/manifest.dart';
import 'package:tsumugi/sources/registry/providers.dart';
import 'package:tsumugi/sources/script/script_source.dart';
import 'package:tsumugi/sources/script/script_source_factory.dart';
import 'package:tsumugi/sources/source.dart';

import '../../core/network/mock_support.dart';
import '../../core/storage/test_database.dart';

const _fixtures = 'test/fixtures/script';

SourceManifest _comicManifest() {
  final json = jsonDecode(
    File('$_fixtures/comic/source.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  json['script'] = File('$_fixtures/comic/source.js').readAsStringSync();
  return SourceManifest.fromJson(json);
}

SourceManifest _hostManifest({String id = 'com.example.script.host'}) =>
    SourceManifest(
      apiVersion: 1,
      id: id,
      name: '宿主 API 测试',
      type: MediaType.novel,
      version: '1.0.0',
      baseUrl: 'http://comic.example.com',
      allowedHosts: const ['img.example.com'],
      engine: SourceEngine.script,
      script: File('$_fixtures/host_api.js').readAsStringSync(),
    );

class _FakeUi implements ScriptUi {
  final requests = <WebViewRequest>[];
  final toasts = <String>[];

  @override
  Future<void> openWebView(WebViewRequest request) async =>
      requests.add(request);

  @override
  void toast(String sourceId, String message) =>
      toasts.add('$sourceId:$message');
}

class _SlowStorage extends MemorySourceStorage {
  @override
  Future<int> usage(String sourceId) async {
    final used = await super.usage(sourceId);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return used;
  }
}

Matcher _sourceError(SourceErrorCode code, {int? status}) =>
    isA<SourceException>()
        .having((e) => e.code, 'code', code)
        .having((e) => e.status, 'status', status);

void main() {
  late MockServer server;
  late SourceStorage storage;
  late List<String> logs;
  final created = <ScriptSource>[];

  setUpAll(() async => server = await MockServer.start());
  tearDownAll(() => server.close());

  setUp(() {
    storage = MemorySourceStorage();
    logs = [];
  });
  tearDown(() {
    for (final s in created) {
      s.dispose();
    }
    created.clear();
  });

  Future<ScriptSource> open(
    SourceManifest manifest, {
    Map<String, Object?> settings = const {},
    ScriptUi ui = const UnavailableScriptUi(),
    ScriptHostLimits hostLimits = const ScriptHostLimits(),
    ScriptLimits limits = const ScriptLimits(),
    SourceStorage? store,
  }) async {
    final source = await ScriptSource.create(
      manifest: manifest,
      http: mockClient(
        server,
        sourceId: manifest.id,
        baseUrl: manifest.baseUrl,
        allowedHosts: manifest.allowedHosts,
        headers: manifest.headers,
      ),
      storage: store ?? storage,
      ui: ui,
      settings: settings,
      log: logs.add,
      hostLimits: hostLimits,
      limits: limits,
    );
    created.add(source);
    return source;
  }

  group('comic script source', () {
    test('search → detail → content', () async {
      final source = await open(_comicManifest());

      final page = await source.search('星', 1);
      expect(page.hasMore, isTrue);
      expect(page.items, hasLength(2));
      final first = page.items.first;
      expect(first.id, '/comic/book/1');
      expect(first.title, '星之栖处');
      expect(first.subtitle, '虚构作者甲');
      expect(first.cover, 'http://img.example.com/covers/1.png');
      expect(first.coverHeaders, {'Referer': 'http://comic.example.com/'});

      final last = await source.search('星', 3);
      expect(last.items, isEmpty);
      expect(last.hasMore, isFalse);

      final detail = await source.detail(first.id);
      expect(detail.title, '星之栖处');
      expect(detail.author, '虚构作者甲');
      expect(detail.description, '一个关于在星星上搭建小屋的虚构故事。');
      expect(detail.tags, ['奇幻', '日常']);
      expect(detail.status, SeriesStatus.ongoing);
      expect(detail.cover, 'http://img.example.com/covers/1.png');
      expect(detail.units.map((u) => u.id), [
        '/comic/book/1/chapter/1',
        '/comic/book/1/chapter/2',
        '/comic/book/1/chapter/3',
      ]);
      expect(detail.units.first.title, '第 1 话 落脚点');
      expect(detail.units.map((u) => u.index), [0, 1, 2]);

      final content = await source.content(detail.units.first.id);
      expect(content, isA<ComicContent>());
      final images = (content as ComicContent).images;
      expect(images.map((i) => i.url), [
        'http://img.example.com/pages/1/1/001.png',
        'http://img.example.com/pages/1/1/002.png',
        'http://img.example.com/pages/1/1/003.png',
      ]);
      expect(images.first.headers, {
        'Referer': 'http://comic.example.com/',
        'X-Quality': 'high',
      });
      // 请求带上了清单的 headers。
      final req = server.requests.lastWhere(
        (r) => r.path == '/comic/book/1/chapter/1',
      );
      expect(req.headers['referer'], 'http://comic.example.com/');
    });

    test('explore and user settings', () async {
      final source = await open(_comicManifest(), settings: {'quality': 'low'});
      expect(await source.explore(), [
        const ExploreCategory(id: 'all', name: '全部'),
      ]);
      expect((await source.exploreList('all', 1)).items, hasLength(2));
      final content =
          await source.content('/comic/book/1/chapter/1') as ComicContent;
      expect(content.images.first.headers?['X-Quality'], 'low');
    });

    test('created through the registered factory', () async {
      final db = openTestDatabase();
      final container = ProviderContainer(
        overrides: [appDatabaseProvider.overrideWithValue(db)],
      );
      addTearDown(() async {
        container.dispose();
        await db.close();
      });
      expect(
        container.read(sourceFactoriesProvider).supports(SourceEngine.script),
        isTrue,
      );

      final factories = SourceFactories([
        ScriptSourceFactory(
          storage: storage,
          httpClientFor: (m) => mockClient(
            server,
            sourceId: m.id,
            baseUrl: m.baseUrl,
            allowedHosts: m.allowedHosts,
          ),
          log: logs.add,
        ),
      ]);
      final source = await factories.create(_comicManifest()) as ScriptSource;
      created.add(source);
      expect((await source.search('x', 1)).items.first.title, '星之栖处');
    });
  });

  group('loading', () {
    test('syntax error → E_PARSE', () async {
      await expectLater(
        open(_hostManifest().copyWith(script: 'export function (')),
        throwsA(_sourceError(SourceErrorCode.parse)),
      );
    });

    test('script given as a relative path is not supported yet', () async {
      await expectLater(
        open(_hostManifest().copyWith(script: 'source.js')),
        throwsA(_sourceError(SourceErrorCode.unsupported)),
      );
    });

    test('unimplemented entry → E_UNSUPPORTED', () async {
      final source = await open(_hostManifest());
      await expectLater(
        source.search('x', 1),
        throwsA(_sourceError(SourceErrorCode.unsupported)),
      );
    });
  });

  group('errors', () {
    test('host errors keep their code and status inside the script', () async {
      final source = await open(_hostManifest());
      expect(await source.debugCall('httpStatus', ['/status/404']), {
        'code': 'E_HTTP',
        'status': 404,
      });
      expect(await source.debugCall('httpStatus', ['/challenge']), {
        'code': 'E_CHALLENGE',
        'status': null,
      });
      expect(
        await source.debugCall('httpStatus', ['http://outside.example.net/']),
        {'code': 'E_HOST_NOT_ALLOWED', 'status': null},
      );
      expect(await source.debugCall('httpStatus', ['/redirect/outside']), {
        'code': 'E_HOST_NOT_ALLOWED',
        'status': null,
      });
    });

    test('uncaught errors map to source error codes', () async {
      final source = await open(_hostManifest());
      await expectLater(
        source.debugCall('rethrow', ['/status/410']),
        throwsA(_sourceError(SourceErrorCode.http, status: 410)),
      );
      await expectLater(
        source.debugCall('rethrow', ['http://outside.example.net/']),
        throwsA(_sourceError(SourceErrorCode.hostNotAllowed)),
      );
      await expectLater(
        source.debugCall('scriptThrows'),
        throwsA(_sourceError(SourceErrorCode.loginRequired)),
      );
      await expectLater(
        source.debugCall('scriptHttpError'),
        throwsA(_sourceError(SourceErrorCode.http, status: 418)),
      );
      await expectLater(
        source.debugCall('typeError'),
        throwsA(_sourceError(SourceErrorCode.parse)),
      );
      await expectLater(
        source.debugCall('getJson', ['/comic/book/1']),
        throwsA(_sourceError(SourceErrorCode.parse)),
      );
    });

    test(
      'http.request returns non-2xx responses and supports options',
      () async {
        final source = await open(_hostManifest());
        final notFound = await source.debugCall('rawRequest', [
          {'url': '/status/404'},
        ]) as Map;
        expect(notFound['status'], 404);

        final post = await source.debugCall('rawRequest', [
          {
            'url': '/echo',
            'method': 'post',
            'body': {'a': 1},
            'responseType': 'json',
          },
        ]) as Map;
        expect(post['status'], 200);
        final echo = post['body'] as Map;
        expect(echo['method'], 'POST');
        expect(jsonDecode(echo['body'] as String), {'a': 1});
        expect(
          (echo['headers'] as Map)['content-type'],
          startsWith('application/json'),
        );

        final form = await source.debugCall('rawRequest', [
          {
            'url': '/echo',
            'method': 'POST',
            'form': {'q': 'a b'},
            'responseType': 'json',
          },
        ]) as Map;
        expect((form['body'] as Map)['body'], 'q=a+b');

        final redirect = await source.debugCall('rawRequest', [
          {'url': '/redirect?to=/echo', 'followRedirects': false},
        ]) as Map;
        expect(redirect['status'], 302);

        final bytes = await source.debugCall('rawRequest', [
          {'url': '/static/x.png', 'responseType': 'bytes'},
        ]) as Map;
        expect(base64.decode(bytes['body'] as String).take(4), [
          0x89,
          0x50,
          0x4e,
          0x47,
        ]);

        await expectLater(
          source.debugCall('rawRequest', [
            {'url': '/echo', 'method': 'PATCH'},
          ]),
          throwsA(_sourceError(SourceErrorCode.parse)),
        );
      },
    );
  });

  test('at most 50 HTTP requests per entry call', () async {
    final source = await open(_hostManifest());
    final before = server.hits('/echo');
    expect(await source.debugCall('manyRequests', [60]), {
      'done': 50,
      'code': 'E_LIMIT',
    });
    expect(server.hits('/echo') - before, 50);
    // 计数按调用重置。
    expect(await source.debugCall('manyRequests', [3]), {
      'done': 3,
      'code': null,
    });
  });

  group('storage', () {
    test('is isolated per source and persisted', () async {
      final db = openTestDatabase();
      addTearDown(db.close);
      final store = DriftSourceStorage(db);
      final a = await open(_hostManifest(id: 'com.example.a'), store: store);
      final b = await open(_hostManifest(id: 'com.example.b'), store: store);

      await a.debugCall('storageSet', [
        'token',
        {
          'v': 1,
          'list': ['x'],
        },
      ]);
      expect(await a.debugCall('storageGet', ['token']), {
        'v': 1,
        'list': ['x'],
      });
      expect(await b.debugCall('storageGet', ['token']), isNull);

      // 新实例（模拟重启）仍能读到。
      a.dispose();
      final a2 = await open(_hostManifest(id: 'com.example.a'), store: store);
      expect(await a2.debugCall('storageGet', ['token']), {
        'v': 1,
        'list': ['x'],
      });

      await a2.debugCall('storageRemove', ['token']);
      expect(await a2.debugCall('storageGet', ['token']), isNull);
      await a2.debugCall('storageSet', ['n', 3]);
      await a2.debugCall('storageSet', ['n', null]);
      expect(await store.read('com.example.a', 'n'), isNull);
    });

    test('enforces size limits', () async {
      final source = await open(
        _hostManifest(),
        hostLimits: const ScriptHostLimits(
          maxStorageValueChars: 20,
          maxStorageCharsPerSource: 30,
        ),
      );
      await expectLater(
        source.debugCall('storageSet', ['k', 'x' * 30]),
        throwsA(_sourceError(SourceErrorCode.limit)),
      );
      await source.debugCall('storageSet', ['k1', 'x' * 15]);
      // 覆盖同一个键不重复计算。
      await source.debugCall('storageSet', ['k1', 'y' * 15]);
      await expectLater(
        source.debugCall('storageSet', ['k2', 'x' * 15]),
        throwsA(_sourceError(SourceErrorCode.limit)),
      );
    });

    test('quota holds for concurrent writes in one call', () async {
      // 让“读用量”变慢，使并发的 set 必然交错。
      final store = _SlowStorage();
      final source = await open(
        _hostManifest(),
        store: store,
        hostLimits: const ScriptHostLimits(maxStorageCharsPerSource: 40),
      );
      final results = await source.debugCall('storageSetMany', [
        [
          for (var i = 0; i < 5; i++) ['k$i', 'x' * 15],
        ],
      ]) as List;
      expect(results.where((r) => r == 'ok'), hasLength(2));
      expect(results.where((r) => r == 'E_LIMIT'), hasLength(3));
      expect(
        await store.usage('com.example.script.host'),
        lessThanOrEqualTo(40),
      );
    });

    test('is cleared when the source is uninstalled', () async {
      final db = openTestDatabase();
      addTearDown(db.close);
      final store = DriftSourceStorage(db);
      final registry = SourceRegistry(db);
      final manifest = _hostManifest();
      await registry.importText(jsonEncode(manifest.toJson()));
      await store.write(manifest.id, 'k', '1');
      await store.write('com.example.other', 'k', '2');
      expect(await registry.remove(manifest.id), isTrue);
      expect(await store.read(manifest.id, 'k'), isNull);
      expect(await store.read('com.example.other', 'k'), '2');
    });
  });

  group('cookies', () {
    test('are isolated per source and limited to allowed hosts', () async {
      final a = await open(_hostManifest(id: 'com.example.a'));
      final b = await open(_hostManifest(id: 'com.example.b'));

      await a.debugCall('cookieSet', ['/', 'sid', 'abc']);
      expect(await a.debugCall('cookieGet', ['http://comic.example.com/x']), {
        'sid': 'abc',
      });
      expect(
        await b.debugCall('cookieGet', ['http://comic.example.com/x']),
        {},
      );

      // 响应中的 Set-Cookie 也进入本源的 Cookie 域，并随后续请求发送。
      await a.debugCall('rawRequest', [
        {'url': '/cookie/set?name=c2&value=v2'},
      ]);
      expect(await a.debugCall('cookieGet', ['/']), {'sid': 'abc', 'c2': 'v2'});
      final echo = await a.debugCall('rawRequest', [
        {'url': '/echo', 'responseType': 'json'},
      ]) as Map;
      expect((echo['body'] as Map)['cookies'], {'sid': 'abc', 'c2': 'v2'});

      expect(
        await a.debugCall('cookieGetCatch', ['http://outside.example.net/']),
        {'code': 'E_HOST_NOT_ALLOWED'},
      );
      await expectLater(
        a.debugCall('cookieSet', ['/', 'bad name', 'v']),
        throwsA(_sourceError(SourceErrorCode.parse)),
      );
    });
  });

  test('html API: HtmlNode handles', () async {
    final source = await open(_hostManifest());
    final r = await source.debugCall('htmlApi') as Map;
    expect(r['count'], 2);
    expect(r['texts'], ['One', 'Two']);
    expect(r['abs'], [
      'http://comic.example.com/p/1',
      'http://comic.example.com/dir/q/2',
    ]);
    expect(r['attr'], '/p/1');
    expect(r['missingAttr'], isNull);
    expect(r['firstNone'], isNull);
    expect(r['html'], 't<b>b</b>');
    expect(r['outer'], '<b>b</b>');
    expect(r['xpathText'], ['One', 'Two']);
    expect(r['xpathAttr'], ['/p/1', 'q/2']);
    expect(r['nested'], 1);
    expect(jsonDecode(r['json'] as String), {'node': '<b>b</b>'});
    expect(r['forged'], 'TypeError');
    expect(r['hiddenRaw'], 'undefined');
    expect(r['keys'], [
      'cookies',
      'crypto',
      'html',
      'http',
      'log',
      'source',
      'storage',
      'ui',
    ]);
    expect(r['frozen'], isTrue);
    expect(r['source'], {
      'id': 'com.example.script.host',
      'baseUrl': 'http://comic.example.com',
      'settings': <String, Object?>{},
    });
    // 句柄只在一次调用内有效。
    expect(
      await source.debugCall('staleNode'),
      startsWith('stale: HtmlNode is no longer valid'),
    );
    await source.debugCall('htmlApi');
    expect(
      await source.debugCall('staleAfterReparse'),
      startsWith('stale: HtmlNode is no longer valid'),
    );
  });

  test('crypto API', () async {
    final source = await open(_hostManifest());
    final r = await source.debugCall('crypto') as Map;
    expect(r['md5'], '900150983cd24fb0d6963f7d28e17f72');
    expect(r['sha1'], 'a9993e364706816aba3e25717850c26c9cd0d89d');
    expect(
      r['sha256'],
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
    expect(
      r['hmac'],
      'f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8',
    );
    expect(r['b64'], base64.encode(utf8.encode('纸鹤')));
    expect(r['unb64'], '纸鹤');
    expect(r['cbcBack'], '纸鹤');
    expect(r['ecb'], hasLength(32));
    expect(r['ecbBack'], 'hello');
    expect(r['gcmBack'], 'gcm text');
    expect(r['badDecrypt'], 'E_PARSE');
  });

  test('log, toast and openWebView', () async {
    final ui = _FakeUi();
    final source = await open(_hostManifest(), ui: ui);
    expect(await source.debugCall('logAndToast'), [true, true]);
    await pumpEventQueue();
    expect(logs, contains('[com.example.script.host] info: hello {"a":1}'));
    expect(ui.toasts, ['com.example.script.host:hi']);

    expect(await source.debugCall('openWebView', ['/login']), 'done');
    final req = ui.requests.single;
    expect(req.url, Uri.parse('http://comic.example.com/login'));
    expect(req.title, 'Login');
    expect(
      req.doneWhenUrlMatches?.hasMatch('http://comic.example.com/members'),
      isTrue,
    );
    expect(identical(req.cookies, source.http), isTrue);

    expect(
      await source.debugCall('openWebView', ['http://outside.example.net/']),
      'E_HOST_NOT_ALLOWED',
    );

    final plain = await open(_hostManifest(id: 'com.example.plain'));
    expect(await plain.debugCall('openWebView', ['/login']), 'E_UNSUPPORTED');
  });

  test('E_LIMIT resets module state; the source stays usable', () async {
    final source = await open(
      _hostManifest().copyWith(
        script:
            '${File('$_fixtures/host_api.js').readAsStringSync()}\n'
            'export function spin() { for (;;) {} }\n',
      ),
      limits: const ScriptLimits(cpuTime: Duration(milliseconds: 200)),
    );
    expect(await source.debugCall('bump'), 1);
    expect(await source.debugCall('bump'), 2);
    await expectLater(
      source.debugCall('spin'),
      throwsA(_sourceError(SourceErrorCode.limit)),
    );
    expect(await source.debugCall('bump'), 1);
  });
}
