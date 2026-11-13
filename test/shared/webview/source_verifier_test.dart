import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/network/source_http_client.dart';
import 'package:tsumugi/core/network/source_session.dart';
import 'package:tsumugi/shared/webview/source_verifier.dart';
import 'package:tsumugi/shared/webview/webview_models.dart';
import 'package:tsumugi/shared/webview/webview_throttle.dart';
import 'package:tsumugi/sources/source.dart';

import 'webview_fakes.dart';

SourceNetworkConfig _config(
  String id, {
  String baseUrl = 'https://comic.example.com',
  List<String> allowedHosts = const ['img.example.com', '*.cdn.example.com'],
  Map<String, String> headers = const {},
}) => SourceNetworkConfig(
  sourceId: id,
  baseUrl: Uri.parse(baseUrl),
  allowedHosts: allowedHosts,
  defaultHeaders: headers,
);

Matcher _sourceError(SourceErrorCode code) =>
    throwsA(isA<SourceException>().having((e) => e.code, 'code', code));

void main() {
  late FakeWebCookieStore store;
  late FakeWebViewLauncher launcher;
  late FakeClock clock;
  late bool foreground;
  late SourceVerifier verifier;

  setUp(() {
    store = FakeWebCookieStore();
    launcher = FakeWebViewLauncher(null, store);
    clock = FakeClock();
    foreground = true;
    verifier = SourceVerifier(
      launcher: launcher,
      cookies: store,
      isForeground: () => foreground,
      throttle: WebViewThrottle(clock: clock.call),
    );
  });

  Future<Map<String, String>> jar(SourceSession s, String url) async => {
    for (final c in await s.cookieJar.loadForRequest(Uri.parse(url)))
      c.name: c.value,
  };

  VerificationRequest request(SourceNetworkConfig config, [String? url]) =>
      VerificationRequest.fromConfig(
        config,
        url: Uri.parse(url ?? '${config.baseUrl}/challenge'),
      );

  test('syncs only allowlisted hosts into the source session', () async {
    final config = _config('a');
    final session = SourceSession();
    launcher.onOpen = (_) {
      // 用户在 WebView 中完成验证：站点与第三方都写了 Cookie。
      store.cookies.addAll(const [
        WebCookie(
          name: 'cf',
          value: 'ok',
          domain: 'comic.example.com',
          httpOnly: true,
        ),
        WebCookie(name: 'img', value: '1', domain: 'img.example.com'),
        WebCookie(name: 'cdn', value: '2', domain: 'a.cdn.example.com'),
        WebCookie(name: 'tracker', value: 'x', domain: 'captcha.example.net'),
      ]);
      return WebViewOutcome(
        completed: true,
        visited: {
          Uri.parse('https://comic.example.com/challenge#frag'),
          Uri.parse('https://a.cdn.example.com/check'),
          // 白名单外的地址即使出现在 visited 中也不会被读取。
          Uri.parse('https://captcha.example.net/widget'),
        },
        userAgent: 'WebViewUA/1.0',
      );
    };

    expect(
      await verifier.verify(request(config), session, userInitiated: true),
      isTrue,
    );
    expect(await jar(session, 'https://comic.example.com/x'), {'cf': 'ok'});
    expect(await jar(session, 'https://img.example.com/p.png'), {'img': '1'});
    expect(await jar(session, 'https://a.cdn.example.com/'), {'cdn': '2'});
    expect(await jar(session, 'https://captcha.example.net/'), isEmpty);
    expect(store.queried.map((u) => u.host).toSet(), {
      'comic.example.com',
      'img.example.com',
      'a.cdn.example.com',
    });
    expect(store.queried.every((u) => u.fragment.isEmpty), isTrue);
    // 打开前与结束后各清空一次。
    expect(store.clears, 2);
    expect(store.cookies, isEmpty);
    expect(session.userAgent, 'WebViewUA/1.0');
  });

  test('cookies are read while the page is alive, before it closes', () async {
    final session = SourceSession();
    launcher.onOpen = (_) {
      store.cookies.add(
        const WebCookie(name: 'cf', value: 'ok', domain: 'comic.example.com'),
      );
      return const WebViewOutcome(completed: true);
    };
    expect(
      await verifier.verify(
        request(_config('a')),
        session,
        userInitiated: true,
      ),
      isTrue,
    );
    final events = store.events;
    final closed = events.indexOf('closed');
    final reads = [
      for (final (i, e) in events.indexed)
        if (e.startsWith('read ')) i,
    ];
    expect(reads, isNotEmpty);
    expect(reads.every((i) => i < closed), isTrue, reason: '$events');
    expect(events.indexOf('clear live'), lessThan(closed));
    expect(events.first, 'clear');
    expect(events.last, 'clear');
    expect(launcher.syncedCounts, [1]);
    expect(await jar(session, 'https://comic.example.com/'), {'cf': 'ok'});
  });

  test('a failed cookie read is reported, not counted as zero', () async {
    final session = SourceSession();
    store.failReads = true;
    launcher.onOpen = (_) => const WebViewOutcome(completed: true);
    // 页面在同步失败时不关闭；假页面随后视为用户取消。
    expect(
      await verifier.verify(
        request(_config('a')),
        session,
        userInitiated: true,
      ),
      isFalse,
    );
    expect(
      launcher.syncErrors.single,
      isA<SourceException>().having(
        (e) => e.message,
        'message',
        contains('读取验证页 Cookie 失败'),
      ),
    );
    expect(launcher.syncedCounts, isEmpty);
  });

  test('completing without syncing first is an error', () async {
    launcher
      ..skipComplete = true
      ..onOpen = (_) => const WebViewOutcome(completed: true);
    await expectLater(
      verifier.verify(
        request(_config('a')),
        SourceSession(),
        userInitiated: true,
      ),
      _sourceError(SourceErrorCode.unsupported),
    );
  });

  test(
    'cookies left in the WebView by another source are not synced',
    () async {
      final a = _config('a');
      final b = _config('b');
      final sa = SourceSession();
      final sb = SourceSession();

      launcher.onOpen = (_) {
        store.cookies.add(
          const WebCookie(
            name: 'a_login',
            value: '1',
            domain: 'comic.example.com',
          ),
        );
        return const WebViewOutcome(completed: true);
      };
      await verifier.verify(request(a), sa, userInitiated: true);

      // 模拟清空失败以外的残留：b 打开前 WebView 里还有 a 的 Cookie。
      store.cookies.add(
        const WebCookie(
          name: 'a_leftover',
          value: '1',
          domain: 'comic.example.com',
        ),
      );
      launcher.onOpen = (_) {
        store.cookies.add(
          const WebCookie(
            name: 'b_login',
            value: '1',
            domain: 'comic.example.com',
          ),
        );
        return const WebViewOutcome(completed: true);
      };
      await verifier.verify(request(b), sb, userInitiated: true);

      expect(await jar(sa, 'https://comic.example.com/'), {'a_login': '1'});
      expect(await jar(sb, 'https://comic.example.com/'), {'b_login': '1'});
    },
  );

  test('cancel writes nothing and returns false', () async {
    final session = SourceSession();
    launcher.onOpen = (_) {
      store.cookies.add(
        const WebCookie(name: 'cf', value: '1', domain: 'comic.example.com'),
      );
      return WebViewOutcome.cancelled;
    };
    expect(
      await verifier.verify(
        request(_config('a')),
        session,
        userInitiated: true,
      ),
      isFalse,
    );
    expect(await jar(session, 'https://comic.example.com/'), isEmpty);
    expect(store.cookies, isEmpty);
    expect(session.userAgent, isNull);
  });

  test('manifest User-Agent is passed to the WebView and kept', () async {
    final config = _config('a', headers: {'user-agent': 'ManifestUA/2.0'});
    final session = SourceSession();
    launcher.onOpen = (r) =>
        WebViewOutcome(completed: true, userAgent: '${r.userAgent}-webview');
    await verifier.verify(request(config), session, userInitiated: true);
    expect(launcher.opened.single.userAgent, 'ManifestUA/2.0');
    expect(session.userAgent, isNull);
  });

  test('successful verification clears the remembered challenge URL', () async {
    final session = SourceSession()
      ..lastChallengeUrl = Uri.parse('https://comic.example.com/challenge');
    launcher.onOpen = (_) => const WebViewOutcome(completed: true);
    await verifier.verify(request(_config('a')), session, userInitiated: true);
    expect(session.lastChallengeUrl, isNull);
  });

  test('start URL must be in the allowlist', () async {
    await expectLater(
      verifier.verify(
        request(_config('a'), 'https://outside.example.net/'),
        SourceSession(),
        userInitiated: true,
      ),
      _sourceError(SourceErrorCode.hostNotAllowed),
    );
    expect(launcher.opened, isEmpty);
    expect(store.clears, 0);
  });

  test('does not open when the WebView store cannot be cleared', () async {
    store.failClear = true;
    await expectLater(
      verifier.verify(
        request(_config('a')),
        SourceSession(),
        userInitiated: true,
      ),
      _sourceError(SourceErrorCode.unsupported),
    );
    expect(launcher.opened, isEmpty);
  });

  test('launcher errors propagate and the store is still cleared', () async {
    launcher.onOpen = (_) =>
        throw const SourceException(SourceErrorCode.unsupported, 'no WebView2');
    await expectLater(
      verifier.verify(
        request(_config('a')),
        SourceSession(),
        userInitiated: true,
      ),
      _sourceError(SourceErrorCode.unsupported),
    );
    expect(store.clears, 2);
    expect(verifier.busy, isFalse);
  });

  group('single flight', () {
    test('concurrent requests for the same source share one page', () async {
      final gate = Completer<WebViewOutcome>();
      launcher.onOpen = (_) => gate.future;
      final session = SourceSession();
      final first = verifier.verify(
        request(_config('a')),
        session,
        userInitiated: false,
      );
      final second = verifier.verify(
        request(_config('a')),
        session,
        userInitiated: true,
      );
      // 等待 clearAll 之后的 open。
      await pumpEventQueue();
      expect(verifier.busy, isTrue);
      gate.complete(const WebViewOutcome(completed: true));
      expect(await first, isTrue);
      expect(await second, isTrue);
      expect(launcher.opened, hasLength(1));
      expect(verifier.busy, isFalse);
    });

    test('another source is rejected while a page is open', () async {
      final gate = Completer<WebViewOutcome>();
      launcher.onOpen = (_) => gate.future;
      final first = verifier.verify(
        request(_config('a')),
        SourceSession(),
        userInitiated: true,
      );
      await expectLater(
        verifier.verify(
          request(_config('b')),
          SourceSession(),
          userInitiated: true,
        ),
        _sourceError(SourceErrorCode.challenge),
      );
      gate.complete(WebViewOutcome.cancelled);
      expect(await first, isFalse);
      expect(launcher.opened.map((r) => r.sourceId), ['a']);
    });
  });

  group('script-initiated throttling', () {
    test('rejected when the app is not in the foreground', () async {
      foreground = false;
      await expectLater(
        verifier.verify(
          request(_config('a')),
          SourceSession(),
          userInitiated: false,
        ),
        _sourceError(SourceErrorCode.challenge),
      );
      expect(launcher.opened, isEmpty);
      // 用户主动点击不受影响。
      await verifier.verify(
        request(_config('a')),
        SourceSession(),
        userInitiated: true,
      );
      expect(launcher.opened, hasLength(1));
    });

    test('user-initiated pages do not start the script cooldown', () async {
      final session = SourceSession();
      launcher.onOpen = (_) => WebViewOutcome.cancelled;
      expect(
        await verifier.verify(
          request(_config('a')),
          session,
          userInitiated: true,
        ),
        isFalse,
      );
      launcher.onOpen = (_) => const WebViewOutcome(completed: true);
      expect(
        await verifier.verify(
          request(_config('a')),
          session,
          userInitiated: false,
        ),
        isTrue,
      );
    });

    test('a launcher failure does not start the cooldown', () async {
      launcher.onOpen = (_) =>
          throw const SourceException(SourceErrorCode.unsupported);
      Future<bool> script() => verifier.verify(
        request(_config('a')),
        SourceSession(),
        userInitiated: false,
      );
      await expectLater(script(), _sourceError(SourceErrorCode.unsupported));
      await expectLater(script(), _sourceError(SourceErrorCode.unsupported));
      expect(launcher.opened, hasLength(2));
    });

    test(
      'min interval after completion, longer cooldown after cancel',
      () async {
        final session = SourceSession();
        Future<bool> script(String id) => verifier.verify(
          request(_config(id)),
          session,
          userInitiated: false,
        );

        launcher.onOpen = (_) => const WebViewOutcome(completed: true);
        expect(await script('a'), isTrue);
        await expectLater(script('a'), _sourceError(SourceErrorCode.challenge));
        // 其他源不受影响。
        expect(await script('b'), isTrue);
        clock.advance(const Duration(seconds: 31));
        expect(await script('a'), isTrue);

        launcher.onOpen = (_) => WebViewOutcome.cancelled;
        clock.advance(const Duration(seconds: 31));
        expect(await script('a'), isFalse);
        clock.advance(const Duration(seconds: 31));
        await expectLater(script('a'), _sourceError(SourceErrorCode.challenge));
        // 用户主动打开不受冷却限制。
        expect(
          await verifier.verify(
            request(_config('a')),
            session,
            userInitiated: true,
          ),
          isFalse,
        );
        clock.advance(const Duration(minutes: 3));
        expect(await script('a'), isFalse);
        expect(launcher.opened, hasLength(6));
      },
    );
  });
}
