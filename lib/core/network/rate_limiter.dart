import 'dart:async';

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

  /// 取得一个令牌；返回时即可发出请求。
  Future<void> acquire() {
    final prev = _tail;
    final done = Completer<void>();
    _tail = done.future;
    return prev.then((_) async {
      try {
        while (true) {
          _refill();
          if (_tokens >= 1) {
            _tokens -= 1;
            return;
          }
          final waitMicros = ((1 - _tokens) / _tokensPerMicro).ceil();
          await _delay(Duration(microseconds: waitMicros));
        }
      } finally {
        done.complete();
      }
    });
  }
}
