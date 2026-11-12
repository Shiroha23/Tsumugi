import 'dart:async';
import 'dart:isolate';

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
/// - 主 isolate 只接受“当前进行中的调用”发来的宿主请求；迟到的请求被拒绝。
/// - **看门狗**：每次加载 / 调用若在 `wallTime + hangGrace` 内没有回应，视为 worker 卡死：
///   调用以 `E_LIMIT` 失败，worker 被丢弃（`Isolate.kill(beforeNextEvent)`，回到事件循环时退出），
///   下一次调用时新建 worker 并重新加载脚本。一直卡住（原生代码或 Dart 死循环）的 isolate
///   无法被终止，只能放弃，其线程可能一直占用，见 architecture §6.1 已知限制。
/// - **崩溃**：worker 意外退出时，进行中的操作以 `E_LIMIT` 失败，下一次调用时重建。
/// - 重建等同于 `E_LIMIT` 后的运行时重建：模块级状态被重置（source-spec §4.4）。
/// - 调用串行执行。
class IsolateScriptRuntime implements ScriptRuntime {
  IsolateScriptRuntime({
    Map<String, HostFunction> host = const {},
    Set<String> notifications = const {},
    this.workerHost,
    this.workerHostConfig,
    this.prelude,
    this.limits = const ScriptLimits(),
    this.hangGrace = const Duration(seconds: 5),
    void Function(String message)? log,
  }) : _host = Map.unmodifiable(host),
       _notifications = Set.unmodifiable(notifications),
       _log = log ?? _noLog {
    final unknown = notifications.difference(host.keys.toSet());
    if (unknown.isNotEmpty) {
      throw ArgumentError.value(unknown, 'notifications', 'not in host');
    }
  }

  /// 符合 [ScriptRuntimeFactory] 签名的工厂。注意 [host] 中的函数在脚本侧一律是异步的。
  static ScriptRuntime create({
    required Map<String, HostFunction> host,
    ScriptLimits limits = const ScriptLimits(),
  }) => IsolateScriptRuntime(host: host, limits: limits);

  final WorkerHostFactory? workerHost;
  final Object? workerHostConfig;

  /// 见 [QuickJsScriptRuntime.prelude]。
  final String? prelude;
  final ScriptLimits limits;

  /// 看门狗在 [ScriptLimits.wallTime] 之外额外等待的时间。
  final Duration hangGrace;

  final Map<String, HostFunction> _host;
  final Set<String> _notifications;
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
        _checkAlive();
        switch (_state) {
          case _LoadState.loaded:
            break;
          case _LoadState.failed:
            throw StateError(
              'The script failed to load; create a new runtime.',
            );
          case _LoadState.empty:
            throw StateError('No script loaded.');
        }
        var worker = _worker;
        if (worker == null || !worker.alive) {
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
        return worker.run(['call', ++_nextCallId, export, args]);
      });

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
  Isolate? _isolate;
  SendPort? _send;
  bool _dead = false;

  /// 进行中的加载 / 调用。
  int? _activeId;
  Completer<Object?>? _pending;
  Timer? _watchdog;
  Completer<void>? _ready;

  bool get alive => !_dead;

  Future<void> start() async {
    final ready = _ready = Completer<void>();
    _inbox.listen(_onMessage);
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
          workerHost: owner.workerHost,
          workerHostConfig: owner.workerHostConfig,
          prelude: owner.prelude,
          limits: owner.limits,
        ),
        debugName: 'tsumugi-script-worker',
        onExit: _inbox.sendPort,
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
        shutdown(const ScriptException('Script worker did not start.'));
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
    _pending = pending;
    _watchdog = Timer(owner.limits.wallTime + owner.hangGrace, () {
      if (_activeId != id) return;
      owner._log(
        '脚本 worker 在 ${owner.limits.wallTime + owner.hangGrace} 内没有回应，'
        '已放弃并将在下次调用时重建（若卡在原生代码中，该 isolate 可能无法被终止）',
      );
      shutdown(
        const ScriptException(
          'Script worker became unresponsive.',
          code: ScriptException.limit,
        ),
      );
    });
    _send!.send(message);
    return pending.future;
  }

  void shutdown(ScriptException reason) {
    if (_dead) return;
    _dead = true;
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
      case null:
        // onExit
        owner._log('脚本 worker 意外退出');
        shutdown(
          const ScriptException(
            'Script worker exited unexpectedly.',
            code: ScriptException.limit,
          ),
        );
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
    Future.sync(() => fn(args)).then(
      (v) {
        // 调用已结束：结果丢弃（worker 也会丢弃）。
        if (callId == _activeId) reply(true, v);
      },
      onError: (Object e, StackTrace _) {
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
    required this.workerHost,
    required this.workerHostConfig,
    required this.prelude,
    required this.limits,
  });

  final SendPort main;
  final List<String> remote;
  final List<String> notifications;
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
