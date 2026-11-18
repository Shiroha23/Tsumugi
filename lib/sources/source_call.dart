import 'dart:async';

import 'source.dart';

/// 界面层的一次源调用（含首次创建源实例）的控制：可取消（docs/architecture.md §5.3，#65）。
///
/// 通过 zone 传给源：在 [run] 内发起的入口调用归属于本票据。支持取消的源（脚本源）
/// 在入口调用开始时读取 [current]：
/// - 票据已取消时不再执行，直接以 [SourceCallCancelledException] 失败（排队中的调用因此不会占用该源）；
/// - 执行中被取消时中止脚本调用，释放该源的串行队列。
/// 不支持取消的源忽略票据，调用照常完成（结果被调用方丢弃）。
final class SourceCallTicket {
  static final _zoneKey = Object();

  /// 当前 zone 中的票据；不在 [run] 内时为 null。
  static SourceCallTicket? get current =>
      Zone.current[_zoneKey] as SourceCallTicket?;

  bool _cancelled = false;
  bool _awaitedUser = false;
  final _listeners = <void Function()>[];

  bool get cancelled => _cancelled;

  /// 本票据的调用曾等待用户操作（打开过验证 / 登录页）。由源在交互式宿主调用开始时标记。
  bool get awaitedUser => _awaitedUser;

  void markAwaitedUser() => _awaitedUser = true;

  /// 在本票据的 zone 中执行 [body]。
  R run<R>(R Function() body) => runZoned(body, zoneValues: {_zoneKey: this});

  /// 取消。重复调用无效。
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final l in List.of(_listeners)) {
      l();
    }
    _listeners.clear();
  }

  /// 取消时调用 [listener]（已取消则立即调用）。返回的函数用于注销。
  void Function() onCancel(void Function() listener) {
    if (_cancelled) {
      listener();
      return () {};
    }
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }
}

/// 能报告“正在等待用户操作”的源（脚本源的 `tsumugi.ui.openWebView`）。
///
/// 等待期间（含排在这次等待之后的调用）界面层超时暂停，见 [runSourceCall]。
abstract interface class UserWaitReporting {
  /// 该源当前是否有入口调用在等待用户操作。
  bool get waitingForUser;

  /// [waitingForUser] 的变化。
  Stream<bool> get waitingForUserChanges;
}

/// 调用被 [SourceCallTicket] 取消。
class SourceCallCancelledException implements Exception {
  const SourceCallCancelledException();

  @override
  String toString() => 'SourceCallCancelledException';
}

/// [runSourceCall] 超时；底层调用已被取消。
class SourceCallTimeoutException extends TimeoutException {
  SourceCallTimeoutException(Duration duration, {this.awaitedUser = false})
    : super('源调用超时', duration);

  /// 这次调用期间该源曾等待用户操作（验证 / 登录页）：界面应提供「打开验证页」。
  final bool awaitedUser;
}

/// 带界面层超时执行一次源调用：[acquire] 取得（可能新建）源实例，[run] 发起入口调用。
///
/// - 超时 [timeout] 计入创建实例、排队与执行的时间；源报告等待用户操作
///   （[UserWaitReporting]，含排在一次等待之后）期间暂停计时。等待结束后**重新给出完整的
///   [timeout]**：用户刚完成验证，后续请求不应因此前用掉的时间而被取消。
///   等待用户本身另由脚本沙箱限时（source-spec §4.4）。
/// - 超时后取消这次调用（[ticket]，缺省新建），以 [SourceCallTimeoutException] 失败；
///   之后底层调用的结果或错误被丢弃。调用方也可以自行 `ticket.cancel()`（如被新的搜索取代），
///   此时以 [SourceCallCancelledException] 失败。
Future<T> runSourceCall<T>({
  required Future<Source> Function() acquire,
  required Future<T> Function(Source source) run,
  required Duration timeout,
  SourceCallTicket? ticket,
}) {
  final t = ticket ?? SourceCallTicket();
  final done = Completer<T>();
  final clock = Stopwatch()..start();
  Timer? timer;
  StreamSubscription<bool>? waits;
  var paused = false;

  void finish() {
    timer?.cancel();
    clock.stop();
    unawaited(waits?.cancel());
  }

  void onTimeout() {
    if (done.isCompleted) return;
    finish();
    t.cancel();
    done.completeError(
      SourceCallTimeoutException(timeout, awaitedUser: t.awaitedUser),
    );
  }

  void arm() {
    timer?.cancel();
    if (paused || done.isCompleted) return;
    final left = timeout - clock.elapsed;
    timer = Timer(left.isNegative ? Duration.zero : left, onTimeout);
  }

  void setPaused(bool value) {
    if (value == paused || done.isCompleted) return;
    paused = value;
    if (value) {
      clock.stop();
      timer?.cancel();
    } else {
      clock
        ..reset()
        ..start();
      arm();
    }
  }

  arm();
  t
      .run(() async {
        final source = await acquire();
        if (t.cancelled) throw const SourceCallCancelledException();
        if (source is UserWaitReporting) {
          final reporting = source as UserWaitReporting;
          waits = reporting.waitingForUserChanges.listen(setPaused);
          setPaused(reporting.waitingForUser);
        }
        return run(source);
      })
      .then(
        (value) {
          if (done.isCompleted) return;
          finish();
          done.complete(value);
        },
        onError: (Object e, StackTrace st) {
          if (done.isCompleted) return;
          finish();
          done.completeError(e, st);
        },
      );
  return done.future;
}
