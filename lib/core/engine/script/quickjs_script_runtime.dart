import 'dart:async';
import 'dart:convert';

import 'package:qjs/qjs.dart';

import 'script_runtime.dart';

/// 基于 `package:qjs`（QuickJS-ng，经 Dart build hooks 编译）的 [ScriptRuntime]。
///
/// 执行模型：
/// - JS 在调用方 isolate 上同步执行；所有“进入 JS”的点（调用导出、resolve 宿主
///   Promise）都包在 [_enterJs] 里，按“剩余 CPU 预算”与“剩余总时长”中较小者设置
///   QuickJS 的中断 deadline，因此死循环会在预算耗尽时被引擎中断（不可被脚本 catch）。
///   检查脚本抛出的异常对象（其 getter 可能执行脚本代码）也在 deadline 内完成。
/// - 等待宿主 Future 的时间不计入 CPU 预算，只计入 [ScriptLimits.wallTime]。
/// - 同一实例上的 [call] 串行执行（宿主 Promise 需要知道属于哪一次调用）。
/// - 不设置 module loader，脚本内 `import` 一律失败；关闭 `eval` / `Function`。
///
/// 已知限制：JS 执行期间会阻塞所在 isolate。正式接入时应把运行时放进 worker isolate
/// （接口已全部异步，调用方无需改动）。
class QuickJsScriptRuntime implements ScriptRuntime {
  QuickJsScriptRuntime({
    required Map<String, HostFunction> host,
    this.limits = const ScriptLimits(),
  }) : _rt = JSRuntime.create(
         JSRuntimeConfig(
           enableEval: false,
           memoryLimit: limits.memoryBytes,
           maxStackSize: limits.maxStackBytes,
         ),
       ) {
    // 在脚本有机会篡改全局对象之前，先拿到要用的内建函数。
    final global = _rt.global;
    _stringify = global['JSON'].asObject['stringify'].asObject.asFunction;
    final promiseCtor = global['Promise'].asObject;
    _promiseCtor = promiseCtor.asValue;
    _promiseResolve = promiseCtor['resolve'].asObject.asFunction;
    _promiseThen =
        promiseCtor['prototype'].asObject['then'].asObject.asFunction;
    _errorCtor = global['Error'].asObject.asFunction;
    _rt.onUncaughtError = (_) {};
    _rt.onUnhandledRejection = (_, _, _) {};
    _installHost(host);
  }

  /// 符合 [ScriptRuntimeFactory] 签名的工厂。
  static ScriptRuntime create({
    required Map<String, HostFunction> host,
    ScriptLimits limits = const ScriptLimits(),
  }) => QuickJsScriptRuntime(host: host, limits: limits);

  final ScriptLimits limits;
  final JSRuntime _rt;

  late final JSFunction _stringify;
  late final JSValue _promiseCtor;
  late final JSFunction _promiseResolve;
  late final JSFunction _promiseThen;
  late final JSFunction _errorCtor;

  JSObject? _namespace;
  _Call? _current;
  Future<void> _tail = Future.value();
  bool _disposed = false;

  /// 当前 JS 堆占用（字节），用于诊断与测试。
  int get memoryUsedBytes => _rt.memoryUsage.memoryUsedSize;

  @override
  Future<void> load(String source, {String name = 'source.js'}) =>
      _serialized(() async {
        _checkAlive();
        if (_namespace != null) {
          throw StateError('A script is already loaded.');
        }
        final call = _Call(limits);
        _current = call;
        try {
          _namespace = _enterJs(
            call,
            () => _rt.evaluateModuleSync(source, name: name),
          );
        } on StateError catch (e) {
          // 顶层 await 仍在等待：源脚本不允许顶层 await。
          throw ScriptException(e.message);
        } finally {
          _current = null;
        }
      });

  @override
  Future<Object?> call(String export, [List<Object?> args = const []]) =>
      _serialized(() => _call(export, args));

  Future<Object?> _call(String export, List<Object?> args) async {
    _checkAlive();
    final ns = _namespace;
    if (ns == null) throw StateError('No script loaded.');

    final fnValue = ns[export];
    if (!fnValue.isObject || !fnValue.asObject.isFunction) {
      throw ScriptException(
        'Export "$export" is not implemented.',
        code: ScriptException.unsupported,
      );
    }
    final fn = fnValue.asObject.asFunction;

    final call = _Call(limits);
    _current = call;
    // 只覆盖“等待宿主 Future”的情况；JS 同步执行时由 [_enterJs] 的 deadline 兜底。
    final timer = Timer(
      limits.wallTime,
      () => call.fail(call.wallLimitError()),
    );

    // 这两个回调在 JS 微任务中运行（已处于 deadline 内）。读取结果 / 异常对象可能
    // 执行脚本代码（toJSON、getter）；若因此被中断，记录失败并把异常交回引擎继续展开。
    final onFulfilled = JSFunction.createFromHostFunction(_rt, (rt, _, a) {
      try {
        call.complete(a.isEmpty ? null : _toDart(a.first));
      } on JSException {
        call.fail(_uninspectable(call));
        rethrow;
      } on Object catch (e) {
        call.fail(_asScriptException(e));
      }
      return JSValue.undefined(rt);
    });
    final onRejected = JSFunction.createFromHostFunction(_rt, (rt, _, a) {
      try {
        call.fail(
          a.isEmpty
              ? const ScriptException('Rejected')
              : _reasonToException(call, a.first),
        );
      } on JSException {
        call.fail(_uninspectable(call));
        rethrow;
      }
      return JSValue.undefined(rt);
    });

    try {
      _enterJs(call, () {
        final result = fn([for (final a in args) _toJs(a)]);
        final promise = _promiseResolve([result], _promiseCtor);
        _promiseThen([onFulfilled.asValue, onRejected.asValue], promise);
      });
    } on Object catch (e) {
      call.fail(_asScriptException(e));
    }

    try {
      return await call.future;
    } finally {
      timer.cancel();
      if (identical(_current, call)) _current = null;
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _current?.fail(const ScriptException('Runtime disposed.'));
    _current = null;
    _namespace = null;
    _rt.release();
  }

  // ---------------------------------------------------------------------------

  Future<T> _serialized<T>(Future<T> Function() body) {
    final result = _tail.then((_) => body());
    _tail = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  void _checkAlive() {
    if (_disposed) throw StateError('Runtime disposed.');
  }

  /// 进入 JS 执行 [body]，按 [call] 剩余的 CPU / 总时长预算（取小）设置中断 deadline。
  ///
  /// JS 异常在 deadline 仍有效时就地转换为 [ScriptException]：异常对象的 getter
  /// 可能是脚本代码，不能在 deadline 之外读取。
  T _enterJs<T>(_Call call, T Function() body) {
    if (call.cpu.isRunning) return body(); // 已在 JS 内（嵌套进入）。
    final remaining = call.remaining;
    if (remaining <= Duration.zero) throw call.timeLimitError();
    _rt.setDeadline(remaining);
    call.cpu.start();
    try {
      return body();
    } on JSException catch (e) {
      throw _inspect(call, e.value);
    } finally {
      call.cpu.stop();
      if (!_disposed) _rt.clearDeadline();
    }
  }

  void _installHost(Map<String, HostFunction> host) {
    final root = JSObject.create(_rt);
    final namespaces = <String, JSObject>{'': root};

    JSObject namespaceFor(List<String> path) {
      final key = path.join('.');
      return namespaces.putIfAbsent(key, () {
        final parent = namespaceFor(path.sublist(0, path.length - 1));
        final obj = JSObject.create(_rt);
        parent[path.last] = obj.asValue;
        return obj;
      });
    }

    host.forEach((path, fn) {
      final segments = path.split('.');
      final owner = namespaceFor(segments.sublist(0, segments.length - 1));
      owner[segments.last] = JSFunction.createFromHostFunction(
        _rt,
        (rt, _, args) => _invokeHost(fn, args),
        name: segments.last,
      ).asObject.asValue;
    });

    for (final ns in namespaces.values) {
      ns.freeze();
    }
    _rt.global['tsumugi'] = root.asValue;
  }

  JSValue _invokeHost(HostFunction fn, List<JSValue> args) {
    final FutureOr<Object?> result;
    try {
      result = fn([for (final a in args) _toDart(a)]);
    } on Object catch (e) {
      throw JSException(_toJsError(e));
    }
    if (result is Future<Object?>) return _bridgeFuture(result);
    try {
      return _toJs(result);
    } on Object catch (e) {
      throw JSException(_toJsError(e));
    }
  }

  /// 把宿主 Future 桥接成 JS Promise。resolve 时重新进入 JS，计入 CPU 预算。
  JSValue _bridgeFuture(Future<Object?> future) {
    final owner = _current;
    final (promise, resolve, reject) = JSPromise.withResolvers(_rt);

    void settle(JSFunction settler, JSValue Function() value) {
      if (_disposed || owner == null || owner.isDone) return;
      if (!identical(_current, owner)) return;
      try {
        _enterJs(owner, () {
          JSValue v;
          try {
            v = value();
          } on Object catch (e) {
            settler = reject;
            v = _toJsError(e);
          }
          settler([v]);
        });
      } on Object catch (e) {
        owner.fail(_asScriptException(e));
      }
    }

    future.then(
      (v) => settle(resolve, () => _toJs(v)),
      onError: (Object e, StackTrace _) => settle(reject, () => _toJsError(e)),
    );
    return promise;
  }

  // --- 值转换 -----------------------------------------------------------------

  Object? _toDart(JSValue value) {
    if (value.isUndefined || value.isNull) return null;
    if (value.isBoolean) return value.asBoolean;
    if (value.isString) return value.asDartString;
    if (value.isNumber) {
      final n = value.asNumber;
      return n == n.truncateToDouble() && n.abs() < 9007199254740992
          ? n.toInt()
          : n;
    }
    final json = _stringify([value]);
    if (json.isUndefined) return null; // 函数、Symbol 等
    return jsonDecode(json.asDartString);
  }

  JSValue _toJs(Object? value) => switch (value) {
    null => JSValue.null_(_rt),
    final bool b => JSValue.boolean(_rt, b),
    final num n => JSValue.number(_rt, n.toDouble()),
    final String s => JSValue.string(_rt, s),
    _ => JSValue.fromJsonUtf8(_rt, utf8.encode(jsonEncode(value))),
  };

  JSValue _toJsError(Object error) {
    final message = switch (error) {
      ScriptException(:final message) => message,
      _ => error.toString(),
    };
    final err = _errorCtor.callAsConstructor([JSValue.string(_rt, message)]);
    if (error is ScriptException && error.code != null) {
      err.asObject['code'] = JSValue.string(_rt, error.code!);
    }
    return err;
  }

  // --- 错误映射 ---------------------------------------------------------------

  /// 不读取 JS 对象，因此可在 deadline 之外安全调用。
  ScriptException _asScriptException(Object error) => switch (error) {
    ScriptException() => error,
    JSException() => const ScriptException('Script error.'),
    _ => ScriptException(error.toString()),
  };

  /// 必须在 [_enterJs] 的 deadline 内调用。
  ScriptException _inspect(_Call call, JSValue reason) {
    try {
      return _reasonToException(call, reason);
    } on JSException {
      return _uninspectable(call);
    }
  }

  ScriptException _uninspectable(_Call call) => call.exhausted
      ? call.timeLimitError()
      : const ScriptException('Script threw a value that could not be read.');

  ScriptException _reasonToException(_Call call, JSValue reason) {
    if (!reason.isObject) {
      String text;
      try {
        text = '${_toDart(reason)}';
      } on Object {
        text = 'Script threw a non-serializable value.';
      }
      return ScriptException(text);
    }
    final obj = reason.asObject;
    String? str(String key) {
      final v = obj[key];
      return v.isString ? v.asDartString : null;
    }

    final name = str('name');
    final message = str('message') ?? 'Script error';
    final stack = str('stack');
    if (name == 'InternalError' && message == 'interrupted') {
      return call.timeLimitError(stack: stack);
    }
    if (message.contains('out of memory')) {
      return ScriptException(
        'Memory limit exceeded (${limits.memoryBytes} bytes).',
        code: ScriptException.limit,
        stack: stack,
      );
    }
    if (name == 'RangeError' && message.contains('stack')) {
      return ScriptException(
        'Stack limit exceeded.',
        code: ScriptException.limit,
        stack: stack,
      );
    }
    return ScriptException(message, code: str('code'), stack: stack);
  }
}

class _Call {
  _Call(this.limits);

  final ScriptLimits limits;
  final cpu = Stopwatch();
  final wall = Stopwatch()..start();
  final _completer = Completer<Object?>();

  Future<Object?> get future => _completer.future;
  bool get isDone => _completer.isCompleted;

  Duration get _cpuLeft => limits.cpuTime - cpu.elapsed;
  Duration get _wallLeft => limits.wallTime - wall.elapsed;

  /// 下一段 JS 执行最多可用的时长。
  Duration get remaining => _cpuLeft < _wallLeft ? _cpuLeft : _wallLeft;

  bool get exhausted => remaining <= Duration.zero;

  ScriptException timeLimitError({String? stack}) => _wallLeft <= _cpuLeft
      ? wallLimitError(stack: stack)
      : ScriptException(
          'CPU time limit exceeded (${limits.cpuTime.inMilliseconds} ms).',
          code: ScriptException.limit,
          stack: stack,
        );

  ScriptException wallLimitError({String? stack}) => ScriptException(
    'Wall time limit exceeded (${limits.wallTime.inMilliseconds} ms).',
    code: ScriptException.limit,
    stack: stack,
  );

  void complete(Object? value) {
    if (isDone) return;
    // 同步 JS 执行期间 Dart 计时器无法触发，完成时再核对一次总时长。
    if (wall.elapsed > limits.wallTime) {
      _completer.completeError(wallLimitError());
    } else {
      _completer.complete(value);
    }
  }

  void fail(ScriptException error) {
    if (!isDone) _completer.completeError(error);
  }
}
