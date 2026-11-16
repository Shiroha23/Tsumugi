import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/network/network_exception.dart';
import 'package:tsumugi/core/network/rate_limiter.dart';
import 'package:tsumugi/core/network/source_http_client.dart';
import 'package:tsumugi/core/network/source_session.dart';

import 'mock_support.dart';

/// 很慢的限速：每 30 s 1 个。第一个请求之后，再计入它的请求在测试时长内都发不出去。
const slow = RateLimitConfig(requests: 1, per: Duration(seconds: 30));

void main() {
  late MockServer server;
  setUpAll(() async => server = await MockServer.start());
  tearDownAll(() => server.close());

  int hits(String query) =>
      server.requests.where((r) => r.query['q'] == query).length;

  /// [pending] 在 [within] 内没有完成（仍在限速队列中）；之后取消它，确认它没有发出请求。
  Future<void> expectQueued(
    Future<Object?> pending,
    NetCancellation cancel,
    String query, {
    Duration within = const Duration(milliseconds: 300),
  }) async {
    var done = false;
    pending.then((_) => done = true, onError: (Object _) => done = true);
    await Future<void>.delayed(within);
    expect(done, isFalse, reason: '应仍在限速队列中');
    cancel.cancel();
    await expectLater(
      pending,
      throwsA(
        isA<NetworkException>().having(
          (e) => e.kind,
          'kind',
          NetworkErrorKind.cancelled,
        ),
      ),
    );
    expect(hits(query), 0, reason: '排队中被取消的请求不应发出');
  }

  group('SourceSession.rateLimiter', () {
    test('取值相同的配置得到同一个桶；null 不限速；媒体通道单独一个桶', () {
      final s = SourceSession();
      final a = s.rateLimiter(
        const RateLimitConfig(requests: 2, per: Duration(seconds: 1)),
      );
      final b = s.rateLimiter(
        const RateLimitConfig(requests: 2, per: Duration(seconds: 1)),
      );
      expect(a, isNotNull);
      expect(identical(a, b), isTrue);
      expect(s.rateLimiter(null), isNull);

      // 源升级改了 rateLimit：新值得到新桶，旧值的桶仍在（旧客户端继续用）。
      final c = s.rateLimiter(
        const RateLimitConfig(requests: 5, per: Duration(seconds: 1)),
      );
      expect(identical(a, c), isFalse);
      expect(
        identical(
          s.rateLimiter(
            const RateLimitConfig(requests: 2, per: Duration(seconds: 1)),
          ),
          a,
        ),
        isTrue,
      );

      final media = s.rateLimiter(null, lane: RateLimitLane.media);
      expect(media, isNotNull);
      expect(identical(media, a) || identical(media, c), isFalse);
      // 媒体通道忽略清单的 rateLimit。
      expect(
        identical(s.rateLimiter(slow, lane: RateLimitLane.media), media),
        isTrue,
      );
      expect(media!.requests, SourceSession.mediaRateLimit.requests);
      expect(media.per, SourceSession.mediaRateLimit.per);
    });

    test('不同会话（不同源）的桶互不相同', () {
      final s1 = SourceSession();
      final s2 = SourceSession();
      expect(identical(s1.rateLimiter(slow), s2.rateLimiter(slow)), isFalse);
      expect(
        identical(
          s1.rateLimiter(null, lane: RateLimitLane.media),
          s2.rateLimiter(null, lane: RateLimitLane.media),
        ),
        isFalse,
      );
    });
  });

  group('同一源的客户端共用令牌桶', () {
    test('源实例与图片客户端（同一会话）共用：一个用掉令牌，另一个要排队', () async {
      final session = SourceSession();
      final sourceClient = mockClient(
        server,
        rateLimit: slow,
        session: session,
      );
      final imageClient = mockClient(server, rateLimit: slow, session: session);
      addTearDown(sourceClient.close);
      addTearDown(imageClient.close);

      await sourceClient.request(const NetRequest('/echo?q=shared-first'));
      final cancel = NetCancellation();
      await expectQueued(
        imageClient.request(
          NetRequest('/echo?q=shared-queued', cancellation: cancel),
        ),
        cancel,
        'shared-queued',
      );
    });

    test('每次播放新建的客户端（openStream）同样计入源的桶', () async {
      final session = SourceSession();
      final sourceClient = mockClient(
        server,
        rateLimit: slow,
        session: session,
      );
      addTearDown(sourceClient.close);
      await sourceClient.request(const NetRequest('/echo?q=play-first'));

      final playClient = mockClient(server, rateLimit: slow, session: session);
      addTearDown(playClient.close);
      final cancel = NetCancellation();
      await expectQueued(
        playClient.openStream(
          NetRequest('/echo?q=play-playlist', cancellation: cancel),
        ),
        cancel,
        'play-playlist',
      );
    });

    test('客户端关闭不影响会话中的桶：新客户端仍要排队', () async {
      final session = SourceSession();
      final first = mockClient(server, rateLimit: slow, session: session);
      await first.request(const NetRequest('/echo?q=closed-first'));
      first.close();

      final second = mockClient(server, rateLimit: slow, session: session);
      addTearDown(second.close);
      final cancel = NetCancellation();
      await expectQueued(
        second.request(
          NetRequest('/echo?q=closed-queued', cancellation: cancel),
        ),
        cancel,
        'closed-queued',
      );
    });
  });

  group('不同源之间隔离', () {
    test('一个源的桶用尽不影响另一个源（同样的 rateLimit）', () async {
      final a = mockClient(
        server,
        sourceId: 'com.example.a',
        rateLimit: slow,
        session: SourceSession(),
      );
      final b = mockClient(
        server,
        sourceId: 'com.example.b',
        rateLimit: slow,
        session: SourceSession(),
      );
      addTearDown(a.close);
      addTearDown(b.close);

      await a.request(const NetRequest('/echo?q=iso-a1'));
      final cancel = NetCancellation();
      final queued = a.request(
        NetRequest('/echo?q=iso-a2', cancellation: cancel),
      );

      final sw = Stopwatch()..start();
      await b.request(const NetRequest('/echo?q=iso-b1'));
      await b
          .openStream(
            const NetRequest('/echo?q=iso-b2'),
            lane: RateLimitLane.media,
          )
          .then((r) => r.cancel());
      expect(sw.elapsedMilliseconds, lessThan(5000));
      await expectQueued(queued, cancel, 'iso-a2', within: Duration.zero);
    });

    test('一个源的媒体配额用尽不影响另一个源', () async {
      final a = CountingSession();
      final ca = mockClient(server, session: a.session);
      final cb = mockClient(server, session: SourceSession());
      addTearDown(ca.close);
      addTearDown(cb.close);

      // 用尽 a 的媒体配额（突发 10 个）。
      final burst = SourceSession.mediaRateLimit.requests;
      await Future.wait([
        for (var i = 0; i < burst; i++)
          ca
              .openStream(
                NetRequest('/echo?q=miso-a$i'),
                lane: RateLimitLane.media,
              )
              .then((r) => r.cancel()),
      ]);
      expect(a.acquiredWith(SourceSession.mediaRateLimit), burst);

      // b 的媒体请求立即放行（同样突发 10 个）。
      final sw = Stopwatch()..start();
      await Future.wait([
        for (var i = 0; i < burst; i++)
          cb
              .openStream(
                NetRequest('/echo?q=miso-b$i'),
                lane: RateLimitLane.media,
              )
              .then((r) => r.cancel()),
      ]);
      // a 的下一个要等约 1 / 10 s；b 不受影响（宽松上限，避免 CI 抖动）。
      expect(sw.elapsedMilliseconds, lessThan(2000));
    });
  });

  group('并发分片请求（媒体通道）', () {
    test('分片不计入源的 rateLimit：源的桶用尽时并发分片照常放行', () async {
      final counting = CountingSession();
      final client = mockClient(
        server,
        rateLimit: slow,
        session: counting.session,
      );
      addTearDown(client.close);

      // 播放列表（源通道）用掉源的唯一令牌。
      (await client.openStream(const NetRequest('/echo?q=seg-playlist')))
          .cancel();

      // 8 个并发分片：都走媒体配额，不必等 30 s。
      final sw = Stopwatch()..start();
      final responses = await Future.wait([
        for (var i = 0; i < 8; i++)
          client.openStream(
            NetRequest('/echo?q=seg-$i'),
            lane: RateLimitLane.media,
          ),
      ]);
      for (final r in responses) {
        expect(r.status, 200);
        r.cancel();
      }
      expect(sw.elapsedMilliseconds, lessThan(5000));
      expect(counting.acquiredWith(slow), 1);
      expect(counting.acquiredWith(SourceSession.mediaRateLimit), 8);

      // 源通道的请求仍要排队。
      final cancel = NetCancellation();
      await expectQueued(
        client.request(NetRequest('/echo?q=seg-api', cancellation: cancel)),
        cancel,
        'seg-api',
      );
    });

    test('媒体配额：突发之后按每秒 10 个放行（虚拟时钟），FIFO 且不丢请求', () async {
      var now = Duration.zero;
      final waits = <Duration>[];
      final session = SourceSession(
        newRateLimiter: (c) => TokenBucket(
          requests: c.requests,
          per: c.per,
          clock: () => now,
          delay: (d) async {
            waits.add(d);
            now += d;
          },
        ),
      );
      final bucket = session.rateLimiter(null, lane: RateLimitLane.media)!;
      final order = <int>[];
      await Future.wait([
        for (var i = 0; i < 15; i++) bucket.acquire().then((_) => order.add(i)),
      ]);
      expect(order, List.generate(15, (i) => i));
      // 前 10 个立即放行，之后 5 个每 100 ms 一个。
      expect(now, const Duration(milliseconds: 500));
    });

    test('未声明 rateLimit 的源：源通道不限速，媒体通道仍有配额', () async {
      final counting = CountingSession();
      final client = mockClient(server, session: counting.session);
      addTearDown(client.close);

      await client.request(const NetRequest('/echo?q=free-api'));
      (await client.openStream(
        const NetRequest('/echo?q=free-seg'),
        lane: RateLimitLane.media,
      )).cancel();
      expect(counting.buckets.map((b) => b.limit), [
        SourceSession.mediaRateLimit,
      ]);
      expect(counting.acquiredWith(SourceSession.mediaRateLimit), 1);
    });

    test('媒体通道的重试与重定向每一跳都计入媒体配额', () async {
      final counting = CountingSession();
      final client = mockClient(server, session: counting.session);
      addTearDown(client.close);
      (await client.openStream(
        const NetRequest('/redirect/chain?n=2'),
        lane: RateLimitLane.media,
      )).cancel();
      expect(counting.acquiredWith(SourceSession.mediaRateLimit), 3);
    });
  });
}
