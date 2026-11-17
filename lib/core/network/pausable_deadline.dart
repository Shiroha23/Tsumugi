import 'dart:async';

/// 可暂停的总时限：未暂停的时间累计达到 [limit] 时调用一次 [onExpired]。
///
/// 本地媒体代理用它实现 `prepareTimeout`：等待限速令牌期间暂停（排队时间不计入），
/// 见 architecture §6.4.3。[pause] / [resume] 可嵌套（并发的多个等待），全部恢复后才继续计时。
class PausableDeadline {
  PausableDeadline(
    Duration limit,
    this._onExpired, {
    Duration Function()? clock,
  }) : _remaining = limit,
       _clock = clock ?? _monotonic() {
    _run();
  }

  final void Function() _onExpired;
  final Duration Function() _clock;
  Duration _remaining;
  late Duration _since;
  Timer? _timer;
  int _pauses = 0;
  bool _finished = false;

  static Duration Function() _monotonic() {
    final sw = Stopwatch()..start();
    return () => sw.elapsed;
  }

  /// 已到时（[onExpired] 已调用）。
  bool get expired => _expired;
  bool _expired = false;

  /// 暂停计时（可嵌套）。
  void pause() {
    if (_finished) return;
    if (_pauses++ == 0) {
      _timer?.cancel();
      _timer = null;
      _remaining -= _clock() - _since;
    }
  }

  /// 撤销一次 [pause]；全部撤销后从剩余时间继续计时。
  void resume() {
    if (_finished || _pauses == 0) return;
    if (--_pauses == 0) _run();
  }

  /// 不再计时（之后不会调用 [onExpired]）。
  void cancel() {
    _finished = true;
    _timer?.cancel();
    _timer = null;
  }

  void _run() {
    _since = _clock();
    _timer = Timer(_remaining.isNegative ? Duration.zero : _remaining, () {
      _finished = true;
      _expired = true;
      _timer = null;
      _onExpired();
    });
  }
}
