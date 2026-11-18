import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/sources/model/common.dart';
import 'package:tsumugi/sources/model/content.dart';
import 'package:tsumugi/sources/model/manifest.dart';
import 'package:tsumugi/sources/runtime/source_error_text.dart';
import 'package:tsumugi/sources/source.dart';
import 'package:tsumugi/sources/source_call.dart';

/// 可控的源：search 在 [gate] 完成前一直等待；[waiting] 模拟“正在等待用户”。
class _FakeSource implements Source, UserWaitReporting {
  final gate = Completer<PageResult<SearchItem>>();
  final _changes = StreamController<bool>.broadcast(sync: true);
  bool _waiting = false;
  SourceCallTicket? seenTicket;

  set waiting(bool value) {
    _waiting = value;
    _changes.add(value);
  }

  @override
  bool get waitingForUser => _waiting;

  @override
  Stream<bool> get waitingForUserChanges => _changes.stream;

  @override
  Future<PageResult<SearchItem>> search(String keyword, int page) {
    seenTicket = SourceCallTicket.current;
    return gate.future;
  }

  @override
  SourceManifest get manifest => throw UnimplementedError();
  @override
  Future<List<ExploreCategory>> explore() => throw UnimplementedError();
  @override
  Future<PageResult<SearchItem>> exploreList(String c, int p) =>
      throw UnimplementedError();
  @override
  Future<Detail> detail(String id) => throw UnimplementedError();
  @override
  Future<MediaContent> content(String unitId) => throw UnimplementedError();
}

const _empty = PageResult<SearchItem>(items: [], hasMore: false);

void main() {
  late _FakeSource source;

  setUp(() => source = _FakeSource());

  Future<PageResult<SearchItem>> call(Duration timeout) => runSourceCall(
    acquire: () async => source,
    run: (s) => s.search('k', 1),
    timeout: timeout,
  );

  test('passes the ticket to the source through the zone', () async {
    final result = call(const Duration(seconds: 5));
    await pumpEventQueue();
    expect(source.seenTicket, isNotNull);
    expect(source.seenTicket!.cancelled, isFalse);
    source.gate.complete(_empty);
    expect(await result, same(_empty));
    expect(SourceCallTicket.current, isNull);
  });

  test('timeout cancels the ticket and fails with a timeout error', () async {
    final result = call(const Duration(milliseconds: 100));
    await expectLater(
      result,
      throwsA(
        isA<SourceCallTimeoutException>().having(
          (e) => e.awaitedUser,
          'awaitedUser',
          isFalse,
        ),
      ),
    );
    expect(source.seenTicket!.cancelled, isTrue);
    // 底层调用之后的结果被丢弃，不会成为未处理的错误。
    source.gate.completeError(const SourceCallCancelledException());
    await pumpEventQueue();
  });

  test('the timeout is paused while the source waits for the user', () async {
    final result = call(const Duration(milliseconds: 200));
    await pumpEventQueue();
    source.waiting = true;
    await Future<void>.delayed(const Duration(milliseconds: 500));
    source.waiting = false;
    source.gate.complete(_empty);
    expect(await result, same(_empty));
    expect(source.seenTicket!.cancelled, isFalse);
  });

  test('time before and after the wait still adds up', () async {
    final result = call(const Duration(milliseconds: 300));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    source.waiting = true;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    source.waiting = false;
    final sw = Stopwatch()..start();
    await expectLater(
      result,
      throwsA(
        isA<SourceCallTimeoutException>().having(
          (e) => e.awaitedUser,
          'awaitedUser',
          isTrue,
        ),
      ),
    );
    // 只剩约 100 ms 的预算。
    expect(sw.elapsed, lessThan(const Duration(milliseconds: 250)));
  });

  test(
    'a source already waiting when the call starts pauses at once',
    () async {
      source.waiting = true;
      final result = call(const Duration(milliseconds: 100));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      source.gate.complete(_empty);
      expect(await result, same(_empty));
    },
  );

  test('ticket listeners', () {
    final ticket = SourceCallTicket();
    var calls = 0;
    final unregister = ticket.onCancel(() => calls++);
    final other = ticket.onCancel(() => calls += 10);
    unregister();
    ticket
      ..cancel()
      ..cancel();
    expect(calls, 10);
    other();
    ticket.onCancel(() => calls += 100);
    expect(calls, 110);
  });

  test('error text: timeouts, cancellation and suspension', () {
    final plain = describeSourceError(
      SourceCallTimeoutException(const Duration(seconds: 30)),
    );
    expect(plain.title, '请求超时');
    expect(plain.needsVerification, isFalse);

    final verify = describeSourceError(
      SourceCallTimeoutException(
        const Duration(seconds: 30),
        awaitedUser: true,
      ),
    );
    expect(verify.title, '等待验证超时');
    expect(verify.needsVerification, isTrue);

    expect(
      describeSourceError(const SourceCallCancelledException()).title,
      '请求已取消',
    );
    final suspended = describeSourceError(
      const SourceSuspendedException('示例源'),
    );
    expect(suspended.title, '「示例源」暂时不可用');
    expect(suspended.needsVerification, isFalse);
  });
}
