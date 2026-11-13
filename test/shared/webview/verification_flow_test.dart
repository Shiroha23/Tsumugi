import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/network/dio_source_http_client.dart';
import 'package:tsumugi/core/network/source_http_client.dart';
import 'package:tsumugi/core/network/source_session.dart';
import 'package:tsumugi/core/storage/app_database.dart';
import 'package:tsumugi/core/storage/source_storage.dart';
import 'package:tsumugi/shared/image/image_providers.dart';
import 'package:tsumugi/shared/webview/source_verification.dart';
import 'package:tsumugi/shared/webview/source_verifier.dart';
import 'package:tsumugi/shared/webview/webview_models.dart';
import 'package:tsumugi/shared/webview/webview_script_ui.dart';
import 'package:tsumugi/sources/declarative/declarative_source_factory.dart';
import 'package:tsumugi/sources/model/manifest.dart';
import 'package:tsumugi/sources/network_error_mapping.dart';
import 'package:tsumugi/sources/registry/providers.dart';
import 'package:tsumugi/sources/runtime/source_runtime.dart';
import 'package:tsumugi/sources/script/script_source_factory.dart';
import 'package:tsumugi/sources/session/source_sessions.dart';
import 'package:tsumugi/sources/source.dart';

import '../../core/network/mock_support.dart';
import '../../core/storage/test_database.dart';
import '../../sources/runtime/runtime_support.dart';
import 'webview_fakes.dart';

/// 端到端：mock 站点的验证 / 登录 → 假 WebView（模拟用户手动提交表单）→ Cookie 回写 → 源请求成功。
void main() {
  late MockServer server;
  late AppDatabase db;
  late SourceRegistry registry;
  late SourceSessions sessions;
  late FakeWebCookieStore store;
  late FakeWebViewLauncher launcher;
  late SourceVerifier verifier;
  late List<String> toasts;
  late SourceFactories factories;
  final created = <Source>[];

  setUpAll(() async => server = await MockServer.start());
  tearDownAll(() => server.close());

  SourceHttpClient clientFor(SourceManifest m) => DioSourceHttpClient(
    networkConfigFromManifest(m),
    session: sessions.of(m.id),
    adapter: mockAdapter(server),
  );

  setUp(() {
    db = openTestDatabase();
    registry = SourceRegistry(db);
    sessions = SourceSessions();
    store = FakeWebCookieStore();
    launcher = FakeWebViewLauncher(null, store);
    verifier = SourceVerifier(launcher: launcher, cookies: store);
    toasts = [];
    factories = SourceFactories([
      DeclarativeSourceFactory(httpClientFor: clientFor, log: (_) {}),
      ScriptSourceFactory(
        storage: MemorySourceStorage(),
        httpClientFor: clientFor,
        ui: WebViewScriptUi(
          verifier: verifier,
          showToast: (id, m) => toasts.add('$id:$m'),
        ),
        log: (_) {},
      ),
    ]);
  });

  tearDown(() async {
    created.forEach(disposeSource);
    created.clear();
    sessions.dispose();
    await db.close();
  });

  Future<(InstalledSource, Source)> install(
    String fixture, [
    Map<String, Object?> changes = const {},
  ]) async {
    final installed = await registry.importText(
      mockSourceJson(fixture, {
        'baseUrl': 'http://comic.example.com',
        ...changes,
      }),
    );
    final source = await factories.create(installed.manifest!);
    created.add(source);
    return (installed, source);
  }

  /// 模拟用户在 WebView 里提交表单：WebView 自己的 Cookie 存储收到响应的 Set-Cookie。
  Future<void> userSubmits(Uri url, Map<String, String> form) async {
    final http = HttpClient()
      ..connectionFactory = (uri, proxyHost, proxyPort) =>
          Socket.startConnect(InternetAddress.loopbackIPv4, server.port);
    try {
      final req = await http.postUrl(url)
        ..followRedirects = false
        ..headers.contentType = ContentType(
          'application',
          'x-www-form-urlencoded',
        )
        ..write(Uri(queryParameters: form).query);
      final res = await req.close();
      await res.drain<void>();
      store.cookies.addAll([
        for (final c in res.cookies)
          WebCookie(
            name: c.name,
            value: c.value,
            domain: url.host,
            path: c.path,
            httpOnly: c.httpOnly,
          ),
      ]);
    } finally {
      http.close(force: true);
    }
  }

  test('E_CHALLENGE → open verification page → retry succeeds', () async {
    final (installed, source) = await install('gated');
    await expectLater(
      source.search('星', 1),
      throwsA(
        isA<SourceException>().having(
          (e) => e.code,
          'code',
          SourceErrorCode.challenge,
        ),
      ),
    );
    final session = sessions.of(installed.id);
    expect(session.lastChallengeUrl?.path, '/gated/comic/search');

    launcher.onOpen = (r) async {
      // 打开的是触发挑战的那个地址；用户手动点「Verify」。
      expect(r.url, session.lastChallengeUrl);
      await userSubmits(r.url.resolve('/challenge/verify'), const {});
      return WebViewOutcome(
        completed: true,
        visited: {r.url, r.url.resolve('/challenge/page')},
      );
    };
    final verification = RegistrySourceVerification(
      registry: registry,
      sessions: sessions,
      verifier: verifier,
    );
    expect(await verification.verifySource(installed.id), isTrue);
    expect(launcher.opened.single.title, contains(installed.name));

    expect((await source.search('星', 1)).items, isNotEmpty);

    // 图片客户端共用该源的会话：同样带上验证 Cookie。
    final images = RegistryImageHttpClients(registry, clientFor: clientFor);
    addTearDown(images.dispose);
    final imageClient = await images.clientFor(installed.id);
    expect(identical(imageClient.session, session), isTrue);
    final echo = await imageClient.getJson('/echo') as Map;
    expect(echo['cookies'], {'verified': '1'});

    // 其他源（即使主机相同）拿不到。
    final other = mockClient(server, sourceId: 'com.example.other');
    addTearDown(other.close);
    expect((await other.getJson('/echo') as Map)['cookies'], isEmpty);
  });

  test('script login via tsumugi.ui.openWebView', () async {
    final (installed, source) = await install('login');
    launcher.onOpen = (r) async {
      expect(r.url, Uri.parse('http://comic.example.com/login'));
      expect(r.doneWhenUrlMatches, r'/members$');
      await userSubmits(r.url, const {'user': 'tester', 'pass': 'secret'});
      return WebViewOutcome(
        completed: true,
        visited: {r.url, r.url.resolve('/members')},
        userAgent: 'WebViewUA/1.0',
      );
    };
    final page = await source.search('星', 1);
    expect(page.items, isNotEmpty);
    expect(launcher.opened, hasLength(1));
    expect(toasts, ['${installed.id}:登录成功']);
    final session = sessions.of(installed.id);
    expect(session.userAgent, 'WebViewUA/1.0');
    final saved = await session.cookieJar.loadForRequest(
      Uri.parse('http://comic.example.com/members'),
    );
    expect(saved.single.name, 'session');
    expect(saved.single.httpOnly, isTrue);

    // 已登录：再次搜索不再弹出验证页。
    await source.search('星', 2);
    expect(launcher.opened, hasLength(1));
  });

  test('script login cancelled by the user → E_LOGIN_REQUIRED', () async {
    final (_, source) = await install('login');
    launcher.onOpen = (_) => WebViewOutcome.cancelled;
    await expectLater(
      source.search('星', 1),
      throwsA(
        isA<SourceException>().having(
          (e) => e.code,
          'code',
          SourceErrorCode.loginRequired,
        ),
      ),
    );
    expect(launcher.opened, hasLength(1));
    // 取消后的冷却期内，脚本再次请求不会弹窗。
    await expectLater(source.search('星', 1), throwsA(isA<SourceException>()));
    expect(launcher.opened, hasLength(1));
  });

  test('sessions are dropped when a source is removed', () async {
    final watching = SourceSessions.watching(registry);
    addTearDown(watching.dispose);
    final (installed, _) = await install('gated');
    final session = watching.of(installed.id)..userAgent = 'x';
    await registry.remove(installed.id);
    for (var i = 0; i < 100 && watching.peek(installed.id) != null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(watching.peek(installed.id), isNull);
    expect(identical(watching.of(installed.id), session), isFalse);
    expect(watching.of(installed.id).userAgent, isNull);
  });
}
