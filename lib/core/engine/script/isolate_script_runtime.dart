import 'dart:async';
import 'dart:isolate';

import 'host/tsumugi_api.dart' show interactiveHostPaths;
import 'quickjs_script_runtime.dart';
import 'script_runtime.dart';

/// worker isolate 内的宿主能力（同步可用）。由 [WorkerHostFactory] 在 worker 中构造。
class WorkerHost {
  const WorkerHost(this.functions, {this.onCallEnd});

  /// 在 worker 内直接执行的宿主函数（如 `crypto.md5`、HTML 句柄操作），
  /// 可以同步返回。键为点分路径，与 [IsolateScriptRuntime.host] 不得重复。
  final Map<String, HostFunction> functions;

  /// 每次加载 / 入口调用结束后调用（无论成败），用于释放本次调用的资源（如 HTML 句柄）。
  final void Function()? onCallEnd;
}

/// 在 worker isolate 中构造 [WorkerHost]。必须是可跨 isolate 发送的函数
/// （顶层函数或静态方法），[config] 必须是可发送的值（建议只用 JSON 兼容值）。
typedef WorkerHostFactory = WorkerHost Function(Object? config);

/// 把 [QuickJsScriptRuntime] 放进独立 worker isolate 的 [ScriptRuntime]
/// （docs/architecture.md §6.1、§5.5）。
///
/// - **宿主函数分三类**：
///   - [host]：在调用方（主）isolate 执行，脚本侧总是得到 Promise（即使函数同步返回）；
///     结果经消息送回 worker。用于网络、存储、Cookie、WebView 等。
///   - [notifications]：[host] 中的一部分路径，按“发出即忘”处理：worker 只发消息、
///     脚本侧同步得到 `undefined`，宿主的返回值与异常都被忽略。用于 `log.*`、`ui.toast`。
///   - [workerHost]：在 worker 内构造并同步执行，用于必须同步返回的 API（crypto、HTML）。
/// - [interactive]：[host] 中需要等待用户操作的路径（如 `ui.openWebView`）。主 isolate 执行
///   它们（且没有其他宿主函数在执行）期间看门狗改按 [ScriptLimits.interactiveTime] 计时，worker 内的总时长同样暂停
///   （[QuickJsScriptRuntime] 的同名参数）。是否处于交互等待只由主 isolate 自己判断，不依赖 worker 的消息。
/// - 主 isolate 只接受“当前进行中的调用”发来的宿主请求；迟到的请求被拒绝。
/// - **看门狗**：每次加载 / 调用若在 `wallTime + hangGrace` 内没有回应（交互等待的时间另按
///   `interactiveTime + hangGrace` 计），视为 worker 卡死：
///   调用以 `E_LIMIT` 失败，worker 被丢弃（`Isolate.kill(beforeNextEvent)`，回到事件循环时退出），
///   下一次调用时新建 worker 并重新加载脚本。一直卡住（原生代码或 Dart 死循环）的 isolate
///   无法被终止，只能放弃，其线程可能一直占用，见 architecture §6.1 已知限制。
/// - **暂时停用**（#29）：看门狗放弃 worker 后，运行时在 [hangCooldown] 内不新建 worker；
///   被放弃、尚未真正退出的 worker 在本实例达到 [maxStuckWorkers] 个、或全进程达到
///   [maxStuckWorkersGlobal] 个时，也不再新建，直到其中有 worker 退出。此期间的调用以
///   `code == E_SUSPENDED` 的 [ScriptException] 立即失败（[suspended] 为 true），
///   这样卡死的源不能反复占用新的线程。
/// - **取消**（#65）：[cancelCurrent] 取消进行中的入口调用。
/// - **崩溃**：worker 意外退出时，进行中的操作以 `E_LIMIT` 失败，下一次调用时重建。
/// - 重建等同于 `E_LIMIT` 后的运行时重建：模块级状态被重置（source-spec §4.4）。
/// - 调用串行执行。
class IsolateScriptRuntime implements ScriptRuntime {
  IsolateScriptRuntime({
    Map<String, HostFunction> host = const {},
    Set<String> notifications = const {},
    Set<String> interactive = const {},
    this.workerHost,
    this.workerHostConfig,
    this.prelude,
    this.limits = const ScriptLimits(),
    this.hangGrace = const Duration(seconds: 5),
    this.hangCooldown = const Duration(minutes: 2),
    this.maxStuckWorkers = 2,
    this.maxStuckWorkersGlobal = 4,
    void Function(String message)? log,
  }) : _host = Map.unmodifiable(host),
       _notifications = Set.unmodifiable(notifications),
       _interactive = Set.unmodifiable(interactive),
       _log = log ?? _noLog {
    final unknown = notifications.difference(host.keys.toSet());
    if (unknown.isNotEmpty) {
      throw ArgumentError.value(unknown, 'notifications', 'not in host');
    }
    final badInteractive = interactive.difference(
      host.keys.toSet().difference(notifications),
    );
    if (badInteractive.isNotEmpty) {
      throw ArgumentError.value(
        badInteractive,
        'interactive',
        'not an asynchronous host path',
      );
    }
  }

  /// 符合 [ScriptRuntimeFactory] 签名的工厂。注意 [host] 中的函数在脚本侧一律是异步的；
  /// 属于 `interactiveHostPaths` 的路径自动按交互式处理。
  static ScriptRuntime create({
    required Map<String, HostFunction> host,
    ScriptLimits limits = const ScriptLimits(),
  }) => IsolateScriptRuntime(
    host: host,
    limits: limits,
    interactive: host.keys.toSet().intersection(interactiveHostPaths),
  );

  final WorkerHostFactory? workerHost;
  final Object? workerHostConfig;

  /// 见 [QuickJsScriptRuntime.prelude]。
  final String? prelude;
  final ScriptLimits limits;

  /// 看门狗在 [ScriptLimits.wallTime] 之外额外等待的时间。
  final Duration hangGrace;

  /// worker 被看门狗放弃后，多久之内不新建 worker（暂时停用）。
  final Duration hangCooldown;

  /// 本实例被放弃、尚未退出的 worker 达到此数量时不再新建 worker。
  final int maxStuckWorkers;

  /// 全进程（所有实例）被放弃、尚未退出的 worker 达到此数量时不再新建 worker。
  final int maxStuckWorkersGlobal;

  /// 全进程被放弃、尚未退出的 worker 数（诊断与测试用）。
  static int get stuckWorkersGlobal => _stuckGlobal;
  static int _stuckGlobal = 0;

  final Map<String, HostFunction> _host;
  final Set<String> _notifications;
  final Set<String> _interactive;
  final void Function(String) _log;

  static void _noLog(String _) {}

  _Worker? _worker;
  _LoadState _state = _LoadState.empty;
  String? _source;
  String? _sourceName;
  bool _disposed = false;
  Future<void> _tail = Future.value();
  int _nextCallId = 0;

  /// 已重建 worker 的次数（诊断与测试用）。
  int get restarts => _restarts;
  int _restarts = 0;

  /// 本实例被放弃、尚未退出的 worker 数。
  int get stuckWorkers => _stuck;
  int _stuck = 0;

  /// 最近一次看门狗放弃 worker 的时刻。
  final _sinceHang = Stopwatch();

  bool _cancelRequested = false;

  /// 运行时是否处于暂时停用状态：worker 已被放弃，且仍在冷却期内或卡住的 worker 过多。
  /// 此时的 [call] 以 `E_SUSPENDED` 立即失败；条件解除后下一次 [call] 照常重建 worker。
  bool get suspended {
    if (_disposed || _state != _LoadState.loaded) return false;
    if (_worker?.alive ?? false) return false;
    return _suspendReason() != null;
  }

  String? _suspendReason() {
    if (_sinceHang.isRunning && _sinceHang.elapsed < hangCooldown) {
      return 'cooling down after an unresponsive worker';
    }
    if (_stuck >= maxStuckWorkers) return 'too many unresponsive workers';
    if (_stuckGlobal >= maxStuckWorkersGlobal) {
      return 'too many unresponsive workers in this process';
    }
    return null;
  }

  void _onHang({required bool counted}) {
    if (counted) {
      _stuck++;
      _stuckGlobal++;
    }
    _sinceHang
      ..reset()
      ..start();
  }

  void _onStuckExited() {
    if (_stuck > 0) _stuck--;
    if (_stuckGlobal > 0) _stuckGlobal--;
  }

  /// 取消进行中的入口调用（#65）：调用以 `code == E_CANCELLED` 的 [ScriptException] 失败，
  /// worker 内的 JS 运行时随后重建（模块级状态重置，同超限）。在 [call] 真正发给 worker
  /// 之前请求的取消同样生效（调用不再发出）。请求在当前调用结束时清除；没有进行中的调用时，
  /// 下一次 [call] 会被取消，因此调用方应只在自己的调用期间调用它（`ScriptSource` 串行执行入口调用）。
  /// worker 正在同步执行 JS 时，取消在这段 JS 结束（最长 `cpuTime`）后生效。
  void cancelCurrent() {
    if (_disposed) return;
    _cancelRequested = true;
    _worker?.cancel();
  }

  static const _cancelledError = ScriptException(
    'Call cancelled.',
    code: ScriptException.cancelled,
  );

  @override
  Future<void> load(String source, {String name = 'source.js'}) =>
      _serialized(() async {
        _checkAlive();
        switch (_state) {
          case _LoadState.loaded:
            throw StateError('A script is already loaded.');
          case _LoadState.failed:
            throw StateError(
              'A previous load failed; create a new runtime instead.',
            );
          case _LoadState.empty:
        }
        try {
          final worker = await _ensureWorker();
          await worker.run(['load', ++_nextCallId, source, name]);
          _source = source;
          _sourceName = name;
          _state = _LoadState.loaded;
        } on Object {
          _state = _LoadState.failed;
          _discardWorker();
          rethrow;
        }
      });

  @override
  Future<Object?> call(String export, [List<Object?> args = const []]) =>
      _serialized(() async {
        try {
          return await _callBody(export, args);
        } finally {
          _cancelRequested = false;
        }
      });

  Future<Object?> _callBody(String export, List<Object?> args) async {
    _checkAlive();
    if (_cancelRequested) throw _cancelledError;
    switch (_state) {
      case _LoadState.loaded:
        break;
      case _LoadState.failed:
        throw StateError('The script failed to load; create a new runtime.');
      case _LoadState.empty:
        throw StateError('No script loaded.');
    }
    var worker = _worker;
    if (worker == null || !worker.alive) {
      final reason = _suspendReason();
      if (reason != null) {
        throw ScriptException(
          'Script runtime suspended: $reason.',
          code: ScriptException.suspended,
        );
      }
      // 上一次调用后 worker 卡死或崩溃：重建并重新加载同一份脚本。
      _discardWorker();
      _restarts++;
      try {
        worker = await _ensureWorker();
        await worker.run(['load', ++_nextCallId, _source!, _sourceName!]);
      } on Object {
        _state = _LoadState.failed;
        _discardWorker();
        rethrow;
      }
    }
    if (_cancelRequested) throw _cancelledError;
    return worker.run(['call', ++_nextCallId, export, args]);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _discardWorker(reason: const ScriptException('Runtime disposed.'));
  }

  // ---------------------------------------------------------------------------

  Future<_Worker> _ensureWorker() async {
    final existing = _worker;
    if (existing != null && existing.alive) return existing;
    final worker = _Worker(this);
    _worker = worker;
    await worker.start();
    return worker;
  }

  void _discardWorker({ScriptException? reason}) {
    _worker?.shutdown(reason ?? const ScriptException('Worker discarded.'));
    _worker = null;
  }

  Future<T> _serialized<T>(Future<T> Function() body) {
    final result = _tail.then((_) => body());
    _tail = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  void _checkAlive() {
    if (_disposed) throw StateError('Runtime disposed.');
  }
}

enum _LoadState { empty, loaded, failed }

/// 主 isolate 一侧对单个 worker 的管理。
class _Worker {
  _Worker(this.owner);

  final IsolateScriptRuntime owner;
  final _inbox = ReceivePort('tsumugi-script-main');

  /// 只接收 onExit。与 [_inbox] 分开：worker 被放弃后 [_inbox] 关闭，但仍需知道
  /// 被放弃的 worker 何时真正退出（之后才不再计入卡住的 worker）。
  final _exitPort = RawReceivePort(null, 'tsumugi-script-exit');
  bool _exited = false;

  /// 被看门狗放弃、计入了卡住的 worker 数（退出时减回）。
  bool _countedStuck = false;

  /// 进行中的是否为入口调用（只有入口调用可以取消）。
  bool _activeIsCall = false;
  Isolate? _isolate;
  SendPort? _send;
  bool _dead = false;

  /// 进行中的加载 / 调用。
  int? _activeId;
  Completer<Object?>? _pending;
  Timer? _watchdog;

  /// 看门狗的计时：进行中的调用已用的总时长（交互等待期间暂停）与交互等待时长。
  final _wallClock = Stopwatch();
  final _interactiveClock = Stopwatch();
  int _interactiveDepth = 0;
  int _plainDepth = 0;

  /// 本次调用是否出现过交互等待。两侧切换计时的时刻不同步（worker 可能正执行最长
  /// `cpuTime` 的同步 JS 才处理宿主结果），出现过时看门狗额外宽限一个 `cpuTime`。
  bool _hadInteractive = false;

  bool get _paused => _interactiveDepth > 0 && _plainDepth == 0;
  Completer<void>? _ready;

  bool get alive => !_dead;

  Future<void> start() async {
    final ready = _ready = Completer<void>();
    _inbox.listen(_onMessage);
    _exitPort.handler = (Object? _) => _onExit();
    // 握手 Future 可能在等待 spawn 时就因 shutdown 失败：先挂上处理，避免未处理的异步错误。
    ready.future.ignore();
    try {
      final isolate = await Isolate.spawn(
        _workerMain,
        _WorkerBoot(
          main: _inbox.sendPort,
          remote: [
            for (final p in owner._host.keys)
              if (!owner._notifications.contains(p)) p,
          ],
          notifications: owner._notifications.toList(),
          interactive: owner._interactive.toList(),
          workerHost: owner.workerHost,
          workerHostConfig: owner.workerHostConfig,
          prelude: owner.prelude,
          limits: owner.limits,
        ),
        debugName: 'tsumugi-script-worker',
        onExit: _exitPort.sendPort,
        onError: _inbox.sendPort,
      );
      if (_dead) {
        // spawn 期间已被 dispose / 放弃：新 isolate 没人管，直接结束它（此时它尚未进入 FFI）。
        isolate.kill(priority: Isolate.immediate);
        throw const ScriptException('Runtime disposed.');
      }
      _isolate = isolate;
    } on ScriptException {
      rethrow;
    } on Object catch (e) {
      // 没有 isolate，也就不会有 onExit。
      _exited = true;
      _exitPort.close();
      shutdown(ScriptException('Failed to start script worker: $e'));
      rethrow;
    }
    // 握手同样受看门狗保护（worker 初始化引擎可能失败）。
    final timer = Timer(owner.limits.wallTime + owner.hangGrace, () {
      if (!ready.isCompleted) {
        ready.completeError(
          const ScriptException(
            'Script worker did not start.',
            code: ScriptException.limit,
          ),
        );
        shutdown(
          const ScriptException('Script worker did not start.'),
          hung: true,
        );
      }
    });
    try {
      await ready.future;
    } finally {
      timer.cancel();
    }
  }

  /// 发出一条加载 / 调用消息并等待结果。消息格式：`[kind, id, ...]`。
  Future<Object?> run(List<Object?> message) {
    if (_dead) {
      return Future.error(
        const ScriptException(
          'Script worker is not running.',
          code: ScriptException.limit,
        ),
      );
    }
    final id = message[1]! as int;
    final pending = Completer<Object?>();
    _activeId = id;
    _activeIsCall = message[0] == 'call';
    _pending = pending;
    _wallClock
      ..reset()
      ..start();
    _interactiveClock
      ..stop()
      ..reset();
    _interactiveDepth = 0;
    _plainDepth = 0;
    _hadInteractive = false;
    _armWatchdog(id);
    _send!.send(message);
    return pending.future;
  }

  /// 按当前计时的预算（总时长或交互等待）加上 [IsolateScriptRuntime.hangGrace] 设置看门狗。
  void _armWatchdog(int id) {
    _watchdog?.cancel();
    final interactive = _paused;
    final budget = interactive
        ? owner.limits.interactiveTime
        : owner.limits.wallTime;
    final used = interactive ? _interactiveClock.elapsed : _wallClock.elapsed;
    final slack = _hadInteractive ? owner.limits.cpuTime : Duration.zero;
    var left = budget + owner.hangGrace + slack - used;
    if (left < Duration.zero) left = Duration.zero;
    _watchdog = Timer(left, () {
      if (_activeId != id) return;
      owner._log(
        '脚本 worker 在 ${budget + owner.hangGrace} 内没有回应，'
        '已放弃并将在下次调用时重建（若卡在原生代码中，该 isolate 可能无法被终止）',
      );
      shutdown(
        const ScriptException(
          'Script worker became unresponsive.',
          code: ScriptException.limit,
        ),
        hung: true,
      );
    });
  }

  /// 请求 worker 取消进行中的入口调用。结果仍经 `done` 消息送回（看门狗照常生效）。
  void cancel() {
    final id = _activeId;
    if (_dead || id == null || !_activeIsCall) return;
    _send?.send(['cancel', id]);
  }

  void _onExit() {
    if (_exited) return;
    _exited = true;
    _exitPort.close();
    if (_countedStuck) {
      _countedStuck = false;
      owner._log('此前无响应的脚本 worker 已退出');
      owner._onStuckExited();
    }
    if (!_dead) {
      owner._log('脚本 worker 意外退出');
      shutdown(
        const ScriptException(
          'Script worker exited unexpectedly.',
          code: ScriptException.limit,
        ),
      );
    }
  }

  void _beginWait(int id, {required bool interactive}) {
    if (_activeId != id) return;
    final was = _paused;
    if (interactive) {
      _interactiveDepth++;
      _hadInteractive = true;
    } else {
      _plainDepth++;
    }
    _switchClock(id, was);
  }

  void _endWait(int id, {required bool interactive}) {
    if (_activeId != id) return;
    final was = _paused;
    if (interactive) {
      if (_interactiveDepth > 0) _interactiveDepth--;
    } else {
      if (_plainDepth > 0) _plainDepth--;
    }
    _switchClock(id, was);
  }

  void _switchClock(int id, bool was) {
    if (_paused == was) return;
    if (_paused) {
      _wallClock.stop();
      _interactiveClock.start();
    } else {
      _interactiveClock.stop();
      _wallClock.start();
    }
    _armWatchdog(id);
  }

  /// [hung]：worker 被判定为无响应而放弃。运行时进入冷却；isolate 已 spawn 且未退出时
  /// 计入卡住的 worker，直到它真正退出。
  void shutdown(ScriptException reason, {bool hung = false}) {
    if (_dead) return;
    _dead = true;
    if (hung) {
      _countedStuck = _isolate != null && !_exited;
      owner._onHang(counted: _countedStuck);
    }
    _finish(error: reason);
    if (!(_ready?.isCompleted ?? true)) _ready!.completeError(reason);
    _send?.send(const ['dispose']);
    // 不能用 Isolate.immediate：worker 可能正处于 QuickJS → Dart 的 FFI 回调中，
    // 在那里被强制终止会让整个进程崩溃。beforeNextEvent 在 worker 回到事件循环时生效；
    // 一直卡住的 worker 只能放弃。
    _isolate?.kill(priority: Isolate.beforeNextEvent);
    _inbox.close();
  }

  void _finish({Object? value, ScriptException? error}) {
    _watchdog?.cancel();
    _watchdog = null;
    _activeId = null;
    _activeIsCall = false;
    final pending = _pending;
    _pending = null;
    if (pending == null || pending.isCompleted) return;
    if (error != null) {
      pending.completeError(error);
    } else {
      pending.complete(value);
    }
  }

  void _onMessage(Object? message) {
    if (_dead) return;
    switch (message) {
      case ['ready', final SendPort port]:
        _send = port;
        _ready?.complete();
      case ['done', final int id, final bool ok, final Object? payload]:
        if (id != _activeId) return;
        if (ok) {
          _finish(value: payload);
        } else {
          final error = _decodeError(payload);
          _watchdog?.cancel();
          _activeId = null;
          final pending = _pending;
          _pending = null;
          pending?.completeError(error);
        }
      case [
        'host',
        final int callId,
        final int reqId,
        final String path,
        final List<Object?> args,
      ]:
        _onHostCall(callId, reqId, path, args);
      case [
        'notify',
        final int callId,
        final String path,
        final List<Object?> args,
      ]:
        if (callId != _activeId) return;
        final fn = owner._host[path];
        if (fn == null) return;
        try {
          final r = fn(args);
          if (r is Future) r.ignore();
        } on Object catch (e) {
          owner._log('宿主通知 $path 出错: $e');
        }
      case [final String? error, final String? _]:
        // onError：未捕获的 Dart 错误（worker 默认 errorsAreFatal，随后会退出）。
        owner._log('脚本 worker 出错: $error');
        shutdown(
          const ScriptException(
            'Script worker crashed.',
            code: ScriptException.limit,
          ),
        );
      default:
        owner._log('脚本 worker 发来未知消息: $message');
    }
  }

  void _onHostCall(int callId, int reqId, String path, List<Object?> args) {
    void reply(bool ok, Object? payload) {
      if (_dead) return;
      _send?.send(['hostResult', reqId, ok, payload]);
    }

    final fn = owner._host[path];
    if (callId != _activeId || fn == null) {
      reply(
        false,
        _encodeError(
          ScriptException(
            fn == null
                ? 'Unknown host function: $path'
                : 'No active call for host function.',
          ),
        ),
      );
      return;
    }
    final interactive = owner._interactive.contains(path);
    _beginWait(callId, interactive: interactive);
    Future.sync(() => fn(args)).then(
      (v) {
        _endWait(callId, interactive: interactive);
        // 调用已结束：结果丢弃（worker 也会丢弃）。
        if (callId == _activeId) reply(true, v);
      },
      onError: (Object e, StackTrace _) {
        _endWait(callId, interactive: interactive);
        if (callId == _activeId) reply(false, _encodeError(e));
      },
    );
  }
}

// --- worker isolate -----------------------------------------------------------

class _WorkerBoot {
  const _WorkerBoot({
    required this.main,
    required this.remote,
    required this.notifications,
    required this.interactive,
    required this.workerHost,
    required this.workerHostConfig,
    required this.prelude,
    required this.limits,
  });

  final SendPort main;
  final List<String> remote;
  final List<String> notifications;
  final List<String> interactive;
  final WorkerHostFactory? workerHost;
  final Object? workerHostConfig;
  final String? prelude;
  final ScriptLimits limits;
}

void _workerMain(_WorkerBoot boot) {
  final inbox = ReceivePort('tsumugi-script-worker');
  final main = boot.main;
  final pendingHost = <int, Completer<Object?>>{};
  var nextReq = 0;
  int? currentId;

  final local = boot.workerHost?.call(boot.workerHostConfig);
  final host = <String, HostFunction>{...?local?.functions};
  for (final path in boot.remote) {
    host[path] = (args) {
      final id = currentId;
      if (id == null) {
        throw const ScriptException('No active call for host function.');
      }
      final req = nextReq++;
      final c = pendingHost[req] = Completer<Object?>();
      main.send(['host', id, req, path, args]);
      return c.future;
    };
  }
  for (final path in boot.notifications) {
    host[path] = (args) {
      final id = currentId;
      if (id != null) main.send(['notify', id, path, args]);
      return null;
    };
  }

  final rt = QuickJsScriptRuntime(
    host: host,
    limits: boot.limits,
    prelude: boot.prelude,
    interactive: boot.interactive.toSet(),
  );

  Future<void> run(int id, Future<Object?> Function() body) async {
    currentId = id;
    try {
      final value = await body();
      main.send(['done', id, true, value]);
    } on Object catch (e) {
      main.send(['done', id, false, _encodeError(e)]);
    } finally {
      currentId = null;
      // 未完成的宿主请求属于已结束的调用：丢弃。
      pendingHost.clear();
      local?.onCallEnd?.call();
    }
  }

  inbox.listen((message) {
    switch (message) {
      case ['load', final int id, final String source, final String name]:
        unawaited(
          run(id, () async {
            await rt.load(source, name: name);
            return null;
          }),
        );
      case [
        'call',
        final int id,
        final String export,
        final List<Object?> args,
      ]:
        unawaited(run(id, () => rt.call(export, args)));
      case ['hostResult', final int req, final bool ok, final Object? payload]:
        final c = pendingHost.remove(req);
        if (c == null) return;
        if (ok) {
          c.complete(payload);
        } else {
          c.completeError(_decodeError(payload));
        }
      case ['cancel', final int id]:
        if (currentId == id) rt.cancelCurrent();
      case ['dispose']:
        rt.dispose();
        inbox.close();
    }
  });
  main.send(['ready', inbox.sendPort]);
}

// --- 错误编码 -----------------------------------------------------------------

Object? _encodeError(Object error) => switch (error) {
  ScriptException(:final message, :final code, :final status, :final stack) => {
    'kind': 'script',
    'message': message,
    'code': code,
    'status': status,
    'stack': stack,
  },
  StateError(:final message) => {'kind': 'state', 'message': message},
  _ => {'kind': 'script', 'message': error.toString()},
};

Object _decodeError(Object? payload) {
  if (payload case {'kind': 'state', 'message': final String message}) {
    return StateError(message);
  }
  if (payload case {'message': final String message}) {
    return ScriptException(
      message,
      code: payload['code'] as String?,
      status: payload['status'] as int?,
      stack: payload['stack'] as String?,
    );
  }
  return ScriptException('$payload');
}
