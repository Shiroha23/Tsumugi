import 'dart:async';

/// 每 [per] 时间内最多 [requests] 个请求（令牌桶，允许突发 [requests] 个）。
///
/// 按值比较：同一个会话中取值相同的配置共用一个令牌桶（`SourceSession.rateLimiter`）。
class RateLimitConfig {
  const RateLimitConfig({required this.requests, required this.per});

  final int requests;
  final Duration per;

  @override
  bool operator ==(Object other) =>
      other is RateLimitConfig &&
      other.requests == requests &&
      other.per == per;

  @override
  int get hashCode => Object.hash(requests, per);

  @override
  String toString() => 'RateLimitConfig($requests / $per)';
}

/// 请求计入哪一个令牌桶（docs/source-spec.md §5）。
enum RateLimitLane {
  /// 清单的 `rateLimit`（未声明时不限速）：规则 / 脚本请求、图片、播放列表、密钥等。
  source,

  /// 本源固定的媒体配额：本地媒体代理转发的 HLS 分片与已确认是媒体的单文件请求。
  media,
}

/// 令牌桶限速器（docs/source-spec.md §1 `rateLimit`）。
///
/// 容量为 [requests]，每 [per] 补充 [requests] 个令牌（匀速补充）。
/// [acquire] 按调用顺序（FIFO）排队，令牌不足时异步等待。
class TokenBucket {
  TokenBucket({
    required this.requests,
    required this.per,
    Duration Function()? clock,
    Future<void> Function(Duration)? delay,
  }) : assert(requests > 0),
       assert(per > Duration.zero),
       _clock = clock ?? _monotonic(),
       _delay = delay ?? Future<void>.delayed,
       _tokens = requests.toDouble() {
    _last = _clock();
  }

  final int requests;
  final Duration per;
  final Duration Function() _clock;
  final Future<void> Function(Duration) _delay;

  double _tokens;
  late Duration _last;
  Future<void> _tail = Future.value();

  static Duration Function() _monotonic() {
    final sw = Stopwatch()..start();
    return () => sw.elapsed;
  }

  double get _tokensPerMicro => requests / per.inMicroseconds;

  void _refill() {
    final now = _clock();
    final elapsed = (now - _last).inMicroseconds;
    if (elapsed > 0) {
      _tokens = (_tokens + elapsed * _tokensPerMicro).clamp(
        0,
        requests.toDouble(),
      );
      _last = now;
    }
  }

  /// 取得一个令牌。返回 true 时即可发出请求。
  ///
  /// [abort] 完成时（例如请求被取消）立即返回 false，且不消耗令牌；
  /// 排在其后的调用不会因它而多等。
  Future<bool> acquire({Future<void>? abort}) {
    final prev = _tail;
    final done = Completer<void>();
    _tail = done.future;
    final result = Completer<bool>();
    var aborted = false;
    abort?.then((_) {
      aborted = true;
      if (!result.isCompleted) result.complete(false);
    });

    () async {
      try {
        await prev;
        while (!aborted) {
          _refill();
          if (_tokens >= 1) {
            _tokens -= 1;
            result.complete(true);
            return;
          }
          final waitMicros = ((1 - _tokens) / _tokensPerMicro).ceil();
          await Future.any([
            _delay(Duration(microseconds: waitMicros)),
            ?abort,
          ]);
        }
      } finally {
        done.complete();
      }
    }();
    return result.future;
  }
}
