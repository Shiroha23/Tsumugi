/// 脚本发起的 `ui.openWebView` 的跨调用频率限制（docs/architecture.md §5.3）。
///
/// 某个源的验证页关闭后，该源由脚本发起的下一次打开至少要等 [minInterval]；
/// 用户取消时改为 [cancelCooldown]。用户主动点击「打开验证页」不受此限制。
class WebViewThrottle {
  WebViewThrottle({
    this.minInterval = const Duration(seconds: 30),
    this.cancelCooldown = const Duration(minutes: 2),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Duration minInterval;
  final Duration cancelCooldown;
  final DateTime Function() _clock;
  final _blockedUntil = <String, DateTime>{};

  /// 还需等待的时长；可以打开时返回 null。
  Duration? blockedFor(String sourceId) {
    final until = _blockedUntil[sourceId];
    if (until == null) return null;
    final left = until.difference(_clock());
    if (left <= Duration.zero) {
      _blockedUntil.remove(sourceId);
      return null;
    }
    return left;
  }

  /// 记录 [sourceId] 的一次验证页关闭。
  void record(String sourceId, {required bool completed}) {
    _blockedUntil[sourceId] = _clock().add(
      completed ? minInterval : cancelCooldown,
    );
  }
}

/// `ui.toast` 的频率限制：每个源每 [interval] 最多一条。
class ToastThrottle {
  ToastThrottle({
    this.interval = const Duration(seconds: 2),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Duration interval;
  final DateTime Function() _clock;
  final _last = <String, DateTime>{};

  /// 允许显示时返回 true 并记录本次。
  bool tryAcquire(String sourceId) {
    final now = _clock();
    final last = _last[sourceId];
    if (last != null && now.difference(last) < interval) return false;
    _last[sourceId] = now;
    return true;
  }
}
