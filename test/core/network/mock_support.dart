import 'dart:async';
import 'dart:io';

import 'package:dio/io.dart';
import 'package:tsumugi/core/network/dio_source_http_client.dart';
import 'package:tsumugi/core/network/rate_limiter.dart';
import 'package:tsumugi/core/network/source_http_client.dart';
import 'package:tsumugi/core/network/source_session.dart';

import '../../../tool/mock_server/mock_server.dart';

export '../../../tool/mock_server/mock_server.dart';

/// 把任意（虚构）主机名的连接都接到本地 [server]，这样测试可以使用
/// `comic.example.com` 之类的地址，同时白名单检查仍按真实主机名进行。
IOHttpClientAdapter mockAdapter(MockServer server) => IOHttpClientAdapter(
  createHttpClient: () =>
      HttpClient()
        ..connectionFactory = (uri, proxyHost, proxyPort) =>
            Socket.startConnect(InternetAddress.loopbackIPv4, server.port),
);

DioSourceHttpClient mockClient(
  MockServer server, {
  String sourceId = 'com.example.comic',
  String baseUrl = 'http://comic.example.com',
  List<String> allowedHosts = const ['img.example.com'],
  Map<String, String> headers = const {},
  Duration timeout = const Duration(seconds: 5),
  RateLimitConfig? rateLimit,
  int maxRetries = 2,
  int maxRedirects = 5,
  int maxResponseBytes = 20 * 1024 * 1024,
  SourceSession? session,
}) => DioSourceHttpClient(
  SourceNetworkConfig(
    sourceId: sourceId,
    baseUrl: Uri.parse(baseUrl),
    allowedHosts: allowedHosts,
    defaultHeaders: headers,
    timeout: timeout,
    rateLimit: rateLimit,
    maxRetries: maxRetries,
    retryBaseDelay: const Duration(milliseconds: 10),
    maxRedirects: maxRedirects,
    maxResponseBytes: maxResponseBytes,
  ),
  adapter: mockAdapter(server),
  session: session,
);

/// 记录取得令牌次数的令牌桶（不改变限速行为）。
class CountingBucket extends TokenBucket {
  CountingBucket(this.limit) : super(requests: limit.requests, per: limit.per);

  final RateLimitConfig limit;
  int acquired = 0;

  @override
  Future<bool> acquire({Future<void>? abort}) async {
    final ok = await super.acquire(abort: abort);
    if (ok) acquired++;
    return ok;
  }
}

/// 一个会话及其创建过的全部令牌桶。
class CountingSession {
  CountingSession() {
    session = SourceSession(
      newRateLimiter: (c) {
        final b = CountingBucket(c);
        buckets.add(b);
        return b;
      },
    );
  }

  late final SourceSession session;
  final buckets = <CountingBucket>[];

  int acquiredWith(RateLimitConfig c) =>
      buckets.where((b) => b.limit == c).fold(0, (sum, b) => sum + b.acquired);
}

/// 手动推进的虚拟时钟：令牌桶的等待只在 [advance] 时结束。
class VirtualClock {
  Duration now = Duration.zero;
  var _tick = Completer<void>();

  /// 给 [TokenBucket] 的 `delay`：等到下一次 [advance]。
  Future<void> delay(Duration _) => _tick.future;

  void advance(Duration d) {
    now += d;
    final t = _tick;
    _tick = Completer<void>();
    t.complete();
  }
}

/// 令牌桶都用 [clock] 计时的会话（并记录取得令牌的次数）。
class VirtualClockSession {
  VirtualClockSession() {
    session = SourceSession(
      newRateLimiter: (c) {
        final b = _VirtualBucket(c, clock);
        buckets.add(b);
        return b;
      },
    );
  }

  final clock = VirtualClock();
  late final SourceSession session;
  final buckets = <_VirtualBucket>[];

  int acquiredWith(RateLimitConfig c) =>
      buckets.where((b) => b.limit == c).fold(0, (sum, b) => sum + b.acquired);
}

class _VirtualBucket extends TokenBucket {
  _VirtualBucket(this.limit, VirtualClock clock)
    : super(
        requests: limit.requests,
        per: limit.per,
        clock: () => clock.now,
        delay: clock.delay,
      );

  final RateLimitConfig limit;
  int acquired = 0;

  @override
  Future<bool> acquire({Future<void>? abort}) async {
    final ok = await super.acquire(abort: abort);
    if (ok) acquired++;
    return ok;
  }
}
