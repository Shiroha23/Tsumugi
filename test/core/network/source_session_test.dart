import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/network/host_policy.dart';
import 'package:tsumugi/core/network/network_exception.dart';
import 'package:tsumugi/core/network/source_http_client.dart';
import 'package:tsumugi/core/network/source_session.dart';

import 'mock_support.dart';

void main() {
  late MockServer server;
  setUpAll(() async => server = await MockServer.start());
  tearDownAll(() => server.close());

  final policy = HostPolicy(
    baseUrl: Uri.parse('http://comic.example.com'),
    allowedHosts: ['img.example.com', '*.cdn.example.com'],
  );
  final comic = Uri.parse('http://comic.example.com/');

  Future<Map<String, String>> cookiesOn(SourceSession s, String url) async => {
    for (final c in await s.cookieJar.loadForRequest(Uri.parse(url)))
      c.name: c.value,
  };

  group('importCookies', () {
    test('saves host-only cookies and keeps attributes', () async {
      final s = SourceSession();
      final n = await s.importCookies(comic, [
        const WebCookie(name: 'cf', value: '1', httpOnly: true),
        const WebCookie(name: 'scoped', value: '2', path: '/members'),
        // 带 Domain：只保存为 comic.example.com 的主机限定 Cookie。
        const WebCookie(name: 'wide', value: '3', domain: '.example.com'),
      ], policy);
      expect(n, 3);

      expect(await cookiesOn(s, 'http://comic.example.com/'), {
        'cf': '1',
        'wide': '3',
      });
      expect(await cookiesOn(s, 'http://comic.example.com/members/x'), {
        'cf': '1',
        'scoped': '2',
        'wide': '3',
      });
      // 同一源的其他白名单主机也拿不到（未在该主机上读取过）。
      expect(await cookiesOn(s, 'http://img.example.com/'), isEmpty);
      final saved = await s.cookieJar.loadForRequest(comic);
      expect(saved.firstWhere((c) => c.name == 'cf').httpOnly, isTrue);
      expect(saved.firstWhere((c) => c.name == 'wide').domain, isNull);
    });

    test('rejects a URL outside the allowlist', () async {
      final s = SourceSession();
      await expectLater(
        s.importCookies(Uri.parse('http://outside.example.net/'), [
          const WebCookie(name: 'a', value: '1'),
        ], policy),
        throwsA(
          isA<NetworkException>().having(
            (e) => e.kind,
            'kind',
            NetworkErrorKind.hostNotAllowed,
          ),
        ),
      );
      expect(await cookiesOn(s, 'http://outside.example.net/'), isEmpty);
    });

    test('skips foreign domains, expired and malformed cookies', () async {
      final s = SourceSession();
      final now = DateTime.utc(2026, 11, 12);
      final n = await s.importCookies(
        comic,
        [
          const WebCookie(name: 'other', value: '1', domain: 'other.example'),
          const WebCookie(
            name: 'sub',
            value: '1',
            domain: 'x.comic.example.com',
          ),
          WebCookie(
            name: 'old',
            value: '1',
            expires: now.subtract(const Duration(seconds: 1)),
          ),
          WebCookie(
            name: 'fresh',
            value: '1',
            expires: now.add(const Duration(days: 1)),
          ),
          const WebCookie(name: 'bad name', value: '1'),
          const WebCookie(name: 'bad', value: 'a;b'),
        ],
        policy,
        now: now,
      );
      expect(n, 1);
      // cookie_jar 用真实时间判断过期，fresh 设在未来足够远处才稳定。
      expect((await s.cookieJar.loadForRequest(comic)).map((c) => c.name), [
        'fresh',
      ]);
    });

    test('wildcard hosts are allowed', () async {
      final s = SourceSession();
      final url = Uri.parse('http://a.cdn.example.com/x');
      expect(
        await s.importCookies(url, [
          const WebCookie(name: 'c', value: '1'),
        ], policy),
        1,
      );
      expect(await cookiesOn(s, 'http://a.cdn.example.com/'), {'c': '1'});
      expect(await cookiesOn(s, 'http://b.cdn.example.com/'), isEmpty);
    });
  });

  group('DioSourceHttpClient with a session', () {
    Future<Map<String, Object?>> echo(SourceHttpClient c, [String? ua]) async =>
        (await c.getJson('/echo', headers: {'User-Agent': ?ua}))!
            as Map<String, Object?>;

    test('clients sharing a session share cookies; others do not', () async {
      final session = SourceSession();
      final a = mockClient(server, session: session);
      final b = mockClient(server, session: session);
      final other = mockClient(server, sourceId: 'com.example.other');
      addTearDown(() {
        a.close();
        b.close();
        other.close();
      });
      await session.importCookies(comic, [
        const WebCookie(name: 'sid', value: 'abc', httpOnly: true),
      ], policy);
      expect(identical(a.session, b.session), isTrue);
      expect((await echo(a))['cookies'], {'sid': 'abc'});
      expect((await echo(b))['cookies'], {'sid': 'abc'});
      expect((await echo(other))['cookies'], isEmpty);
    });

    test('session UA is the lowest-priority default', () async {
      final session = SourceSession()..userAgent = 'WebViewUA/1.0';
      final plain = mockClient(server, session: session);
      final withHeader = mockClient(
        server,
        session: session,
        headers: {'User-Agent': 'ManifestUA/2.0'},
      );
      addTearDown(() {
        plain.close();
        withHeader.close();
      });
      String ua(Map<String, Object?> e) =>
          (e['headers']! as Map)['user-agent'] as String;
      expect(ua(await echo(plain)), 'WebViewUA/1.0');
      expect(ua(await echo(plain, 'Request/3.0')), 'Request/3.0');
      expect(ua(await echo(withHeader)), 'ManifestUA/2.0');
    });

    test('Secure cookies are never sent over http', () async {
      final session = SourceSession();
      final c = mockClient(server, session: session);
      addTearDown(c.close);
      await session.importCookies(Uri.parse('https://comic.example.com/'), [
        const WebCookie(name: 'sec', value: '1', secure: true),
        const WebCookie(name: 'plain', value: '2'),
      ], policy);
      expect((await echo(c))['cookies'], {'plain': '2'});
      expect(
        (await session.cookieJar.loadForRequest(
          Uri.parse('https://comic.example.com/'),
        )).map((c) => c.name).toSet(),
        {'sec', 'plain'},
      );
    });

    test('records the last challenge URL', () async {
      final session = SourceSession();
      final c = mockClient(server, session: session);
      addTearDown(c.close);
      await expectLater(
        c.request(const NetRequest('/challenge/page?from=search')),
        throwsA(isA<NetworkException>()),
      );
      expect(
        session.lastChallengeUrl,
        Uri.parse('http://comic.example.com/challenge/page?from=search'),
      );
    });
  });
}
