import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/network/dio_source_http_client.dart';
import 'package:tsumugi/core/network/source_http_client.dart';
import 'package:tsumugi/shared/webview/source_verifier.dart';
import 'package:tsumugi/shared/webview/url_matcher.dart';
import 'package:tsumugi/shared/webview/webview_models.dart';
import 'package:tsumugi/shared/webview/webview_script_ui.dart';
import 'package:tsumugi/shared/webview/webview_throttle.dart';
import 'package:tsumugi/sources/script/script_ui.dart';
import 'package:tsumugi/sources/source.dart';

import 'webview_fakes.dart';

void main() {
  group('WebViewScriptUi', () {
    late FakeWebViewLauncher launcher;
    late FakeClock clock;
    late bool foreground;
    late List<String> toasts;
    late WebViewScriptUi ui;
    late DioSourceHttpClient http;

    setUp(() {
      final store = FakeWebCookieStore();
      launcher = FakeWebViewLauncher(null, store);
      clock = FakeClock();
      foreground = true;
      toasts = [];
      ui = WebViewScriptUi(
        verifier: SourceVerifier(
          launcher: launcher,
          cookies: store,
          isForeground: () => foreground,
          throttle: WebViewThrottle(clock: clock.call),
        ),
        isForeground: () => foreground,
        toastThrottle: ToastThrottle(clock: clock.call),
        showToast: (id, m) => toasts.add('$id:$m'),
      );
      http = DioSourceHttpClient(
        SourceNetworkConfig(
          sourceId: 'com.example.a',
          baseUrl: Uri.parse('https://comic.example.com'),
          defaultHeaders: const {'User-Agent': 'ManifestUA/2.0'},
        ),
      );
    });
    tearDown(() => http.close());

    WebViewRequest request() => WebViewRequest(
      sourceId: 'com.example.a',
      url: Uri.parse('https://comic.example.com/login'),
      cookies: http,
      title: 'Login',
      doneWhenUrlMatches: '/members',
    );

    test('passes the request through and resolves on completion', () async {
      launcher.onOpen = (_) => const WebViewOutcome(completed: true);
      await ui.openWebView(request());
      final opened = launcher.opened.single;
      expect(opened.url.path, '/login');
      expect(opened.title, 'Login');
      expect(opened.doneWhenUrlMatches, '/members');
      expect(opened.userAgent, 'ManifestUA/2.0');
    });

    test('cancel → E_CHALLENGE', () async {
      await expectLater(
        ui.openWebView(request()),
        throwsA(
          isA<SourceException>().having(
            (e) => e.code,
            'code',
            SourceErrorCode.challenge,
          ),
        ),
      );
    });

    test('script-initiated: not shown in the background', () async {
      foreground = false;
      await expectLater(
        ui.openWebView(request()),
        throwsA(isA<SourceException>()),
      );
      expect(launcher.opened, isEmpty);
    });

    test('toast: at most one per source every 2 s, none in background', () {
      ui
        ..toast('a', 'one')
        ..toast('a', 'two')
        ..toast('b', 'other');
      clock.advance(const Duration(milliseconds: 2100));
      ui.toast('a', 'three');
      foreground = false;
      clock.advance(const Duration(seconds: 5));
      ui.toast('a', 'hidden');
      expect(toasts, ['a:one', 'b:other', 'a:three']);
    });
  });

  group('UrlMatcher', () {
    test('matches in a background isolate', () async {
      final m = UrlMatcher(r'/members$');
      expect(await m.matches('https://comic.example.com/members'), isTrue);
      expect(await m.matches('https://comic.example.com/members/x'), isFalse);
      expect(m.disabled, isFalse);
    });

    test('disables itself after a timeout', () async {
      final never = Completer<bool>();
      var calls = 0;
      final m = UrlMatcher(
        '(a+)+\$',
        timeout: const Duration(milliseconds: 50),
        runner: (_, _) {
          calls++;
          return never.future;
        },
      );
      expect(await m.matches('aaaa'), isFalse);
      expect(m.disabled, isTrue);
      expect(await m.matches('aaaa'), isFalse);
      expect(calls, 1);
    });

    test(
      'evaluations run one at a time; queued ones stop after a timeout',
      () async {
        var running = 0;
        var maxRunning = 0;
        var calls = 0;
        final gates = <Completer<bool>>[];
        final m = UrlMatcher(
          'x',
          timeout: const Duration(milliseconds: 50),
          runner: (_, _) {
            calls++;
            running++;
            if (running > maxRunning) maxRunning = running;
            final c = Completer<bool>();
            gates.add(c);
            // 第一次求值“卡住”，触发超时。
            return c.future.whenComplete(() => running--);
          },
        );
        final results = await Future.wait([
          m.matches('a'),
          m.matches('b'),
          m.matches('c'),
        ]);
        expect(results, [false, false, false]);
        expect(maxRunning, 1);
        expect(calls, 1);
        expect(m.disabled, isTrue);
      },
    );

    test('ignores overlong input', () async {
      var calls = 0;
      final m = UrlMatcher(
        'x',
        maxInputLength: 10,
        runner: (_, _) async {
          calls++;
          return true;
        },
      );
      expect(await m.matches('x' * 11), isFalse);
      expect(calls, 0);
      expect(m.disabled, isFalse);
    });
  });
}
