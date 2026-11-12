import 'dart:async';
import 'dart:isolate';

/// 在后台 isolate 中求值的 [Isolate.run] 等价物；测试可替换。
typedef MatchRunner = Future<bool> Function(String pattern, String input);

Future<bool> _isolateMatch(String pattern, String input) =>
    Isolate.run(() => RegExp(pattern).hasMatch(input));

/// `doneWhenUrlMatches` 的求值器。
///
/// 正则来自源（不可信），可能出现灾难性回溯；因此不在 UI isolate 上求值，而是在后台
/// isolate 中限时执行。一旦超时或出错就停用（之后总是返回 false），只能由用户手动点「完成」。
/// 超时的后台 isolate 无法被强制结束，最坏情况下占用一个线程直到它自行结束。
class UrlMatcher {
  UrlMatcher(
    this.pattern, {
    this.timeout = const Duration(seconds: 1),
    this.maxInputLength = 4096,
    MatchRunner? runner,
  }) : _run = runner ?? _isolateMatch;

  final String pattern;
  final Duration timeout;
  final int maxInputLength;
  final MatchRunner _run;
  bool _disabled = false;

  /// 求值串行执行：同一时刻最多一个后台 isolate，超时停用后排队的请求直接返回 false。
  Future<void> _tail = Future.value();

  /// 超时或出错后为 true。
  bool get disabled => _disabled;

  Future<bool> matches(String input) {
    if (_disabled || input.length > maxInputLength) return Future.value(false);
    final result = _tail.then((_) async {
      if (_disabled) return false;
      try {
        return await _run(pattern, input).timeout(timeout);
      } on Object {
        _disabled = true;
        return false;
      }
    });
    _tail = result;
    return result;
  }
}
