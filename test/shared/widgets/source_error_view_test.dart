import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/shared/webview/providers.dart';
import 'package:tsumugi/shared/widgets/source_error_view.dart';
import 'package:tsumugi/sources/source.dart';

import '../webview/webview_fakes.dart';

void main() {
  late FakeSourceVerification verification;
  late int retries;

  setUp(() {
    verification = FakeSourceVerification();
    retries = 0;
  });

  Future<void> pump(
    WidgetTester tester,
    Object error, {
    String? sourceId = 'com.example.a',
    bool compact = false,
  }) => tester.pumpWidget(
    ProviderScope(
      overrides: [sourceVerificationProvider.overrideWithValue(verification)],
      child: MaterialApp(
        home: Scaffold(
          body: SourceErrorView(
            error: error,
            sourceId: sourceId,
            compact: compact,
            onRetry: () => retries++,
          ),
        ),
      ),
    ),
  );

  for (final code in [
    SourceErrorCode.challenge,
    SourceErrorCode.loginRequired,
  ]) {
    testWidgets('${code.wire}: verify then retry', (tester) async {
      await pump(tester, SourceException(code));
      await tester.tap(find.text('打开验证页'));
      await tester.pumpAndSettle();
      expect(verification.calls, ['com.example.a']);
      expect(retries, 1);
    });
  }

  testWidgets('cancelled verification does not retry', (tester) async {
    verification.result = false;
    await pump(
      tester,
      const SourceException(SourceErrorCode.challenge),
      compact: true,
    );
    await tester.tap(find.text('打开验证页'));
    await tester.pumpAndSettle();
    expect(verification.calls, hasLength(1));
    expect(retries, 0);
  });

  testWidgets('no retry when the view is gone before verification ends', (
    tester,
  ) async {
    final pending = verification.pending = Completer<bool>();
    await pump(tester, const SourceException(SourceErrorCode.challenge));
    await tester.tap(find.text('打开验证页'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    pending.complete(true);
    await tester.pumpAndSettle();
    expect(retries, 0);
  });

  testWidgets('no retry when the view now shows another source', (
    tester,
  ) async {
    final pending = verification.pending = Completer<bool>();
    await pump(tester, const SourceException(SourceErrorCode.challenge));
    await tester.tap(find.text('打开验证页'));
    await tester.pump();
    await pump(
      tester,
      const SourceException(SourceErrorCode.challenge),
      sourceId: 'com.example.b',
    );
    pending.complete(true);
    await tester.pumpAndSettle();
    expect(retries, 0);
  });

  testWidgets('failure to open is reported, no retry', (tester) async {
    verification.error = const SourceException(
      SourceErrorCode.unsupported,
      '未安装 WebView2',
    );
    await pump(tester, const SourceException(SourceErrorCode.challenge));
    await tester.tap(find.text('打开验证页'));
    await tester.pump();
    expect(find.text('无法打开验证页：未安装 WebView2'), findsOneWidget);
    expect(retries, 0);
  });

  testWidgets('no verify button for other errors or without a source', (
    tester,
  ) async {
    await pump(tester, const SourceException(SourceErrorCode.network));
    expect(find.text('打开验证页'), findsNothing);
    expect(find.text('重试'), findsOneWidget);

    await pump(
      tester,
      const SourceException(SourceErrorCode.challenge),
      sourceId: null,
    );
    expect(find.text('需要验证'), findsOneWidget);
    expect(find.text('打开验证页'), findsNothing);
  });
}
