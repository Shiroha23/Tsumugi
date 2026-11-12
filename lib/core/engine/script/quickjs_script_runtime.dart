import 'dart:async';
import 'dart:convert';

import 'package:qjs/qjs.dart';

import 'script_runtime.dart';

/// 基于 `package:qjs`（QuickJS-ng，经 Dart build hooks 编译）的 [ScriptRuntime]。
///
/// 执行模型：
/// - JS 在调用方 isolate 上同步执行；所有“进入 JS”的点（加载模块、调用导出、resolve
///   宿主 Promise）都包在 [_enterJs] 里，按“剩余 CPU 预算”与“剩余总时长”中较小者设置
///   QuickJS 的中断 deadline，因此死循环会在预算耗尽时被引擎中断（不可被脚本 catch）。
///   检查脚本抛出的异常对象（其 getter 可能执行脚本代码）也在 deadline 内完成。
/// - 每次进入 JS 后都在同一 deadline 内清空微任务队列；入口结果只在这一段 JS
///   （含其触发的全部微任务）正常结束后才提交，因此结果之后的超限不会被忽略。
/// - 若微任务队列未能清空（被中断），运行时被标记为“已污染”：调用结束后丢弃整个
///   引擎并重新求值模块，旧任务不会泄漏到下一次调用。代价是模块级状态被重置，
///   需要持久化的数据应使用 `tsumugi.storage`。
/// - 宿主函数只能在进行中的调用里被调用。
/// - 等待宿主 Future 的时间不计入 CPU 预算，只计入 [ScriptLimits.wallTime]。
/// - 同一实例上的 [call] 串行执行（宿主 Promise 需要知道属于哪一次调用）。
/// - 不设置 module loader，脚本内 `import` 一律失败；关闭 `eval` / `Function`。
///
/// 已知限制（见 docs/architecture.md §6.1）：
/// - JS 执行期间会阻塞所在 isolate；脚本源经 `IsolateScriptRuntime` 放在 worker isolate 中运行。
/// - QuickJS 部分原生内建函数内部的循环不检查中断，极端输入可能长时间无法返回。
/// - 内存 / 栈超限表现为分配失败的异常，脚本可以 catch；但超限的分配本身不会成功。
class QuickJsScriptRuntime implements ScriptRuntime {
  ///
  /// [prelude] 为可选的受信任 JS（一个函数表达式，如 `(raw) => api`）：宿主函数先挂到
  /// 冻结的 `raw` 对象上，prelude 以它为参数被调用一次，返回值（冻结后）成为全局
  /// `tsumugi`。用于在 JS 侧包装宿主函数（如 `HtmlNode` 句柄对象），
  /// 未在返回值中暴露的宿主函数对脚本不可见。为 null 时全局 `tsumugi` 即 `raw`。
  QuickJsScriptRuntime({
    required Map<String, HostFunction> host,
    this.limits = const ScriptLimits(),
    this.prelude,
  }) : _host = Map.unmodifiable(host) {
    _initEngine();
  }

  /// 符合 [ScriptRuntimeFactory] 签名的工厂。
  static ScriptRuntime create({
    required Map<String, HostFunction> host,
    ScriptLimits limits = const ScriptLimits(),
  }) => QuickJsScriptRuntime(host: host, limits: limits);

  final ScriptLimits limits;
  final String? prelude;
  final Map<String, HostFunction> _host;

  late JSRuntime _rt;
  late JSFunction _stringify;
  late JSValue _promiseCtor;
  late JSFunction _promiseResolve;
  late JSFunction _promiseThen;
  late JSFunction _errorCtor;

  _LoadState _state = _LoadState.empty;
  String? _source;
  String? _sourceName;
  JSObject? _namespace;

  /// 微任务队列可能残留旧任务，当前调用结束后需要重建引擎。
  bool _poisoned = false;

  _Call? _current;
  Future<void> _tail = Future.value();
  bool _disposed = false;

  /// 当前 JS 堆占用（字节），用于诊断与测试。
  int get memoryUsedBytes => _rt.memoryUsage.memoryUsedSize;

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
          _namespace = _evaluate(source, name);
          _source = source;
          _sourceName = name;
          _state = _LoadState.loaded;
        } on Object {
          // 失败的模块可能已改动全局对象：实例作废，不允许换脚本重试。
          _state = _LoadState.failed;
          _namespace = null;
          rethrow;
        }
      });

  @override
  Future<Object?> call(String export, [List<Object?> args = const []]) =>
      _serialized(() => _call(export, args));

  Future<Object?> _call(String export, List<Object?> args) async {
    _checkAlive();
    final ns = switch (_state) {
      _LoadState.loaded => _namespace!,
      _LoadState.failed => throw StateError(
        'The script failed to load; create a new runtime.',
      ),
      _LoadState.empty => throw StateError('No script loaded.'),
    };

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
    // 结果只暂存，等 [_enterJs] 清空微任务后才提交。
    final onFulfilled = JSFunction.createFromHostFunction(_rt, (rt, _, a) {
      try {
        call.stage(a.isEmpty ? null : _toDart(a.first));
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
      // 触发资源上限的调用（含总时长计时器）之后一律重建，模块状态从头开始。
      if (_poisoned || call.hitLimit) _recover();
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

  void _initEngine() {
    _rt = JSRuntime.create(
      JSRuntimeConfig(
        enableEval: false,
        memoryLimit: limits.memoryBytes,
        maxStackSize: limits.maxStackBytes,
      ),
    );
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
    _installHost(_host);
  }

  /// 求值模块，返回其命名空间。必须在 [_serialized] 内调用。
  JSObject _evaluate(String source, String name) {
    final call = _Call(limits);
    _current = call;
    try {
      return _enterJs(call, () => _rt.evaluateModuleSync(source, name: name));
    } on StateError catch (e) {
      // 顶层 await 仍在等待：源脚本不允许顶层 await。
      throw ScriptException(e.message);
    } finally {
      _current = null;
      // 加载阶段的残留任务同样不能留给第一次调用。
      if (_poisoned) {
        _poisoned = false;
        _replaceEngine();
      }
    }
  }

  /// 丢弃可能残留旧任务的引擎，用同一份源码重建。
  void _recover() {
    _poisoned = false;
    if (_disposed || _state != _LoadState.loaded) return;
    _replaceEngine();
    try {
      _namespace = _evaluate(_source!, _sourceName!);
    } on Object {
      // 同一份源码首次加载成功、重载却失败（例如初始化依赖运行时状态）：作废实例。
      _namespace = null;
      _state = _LoadState.failed;
    }
  }

  void _replaceEngine() {
    final old = _rt;
    _initEngine();
    old.release();
  }

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
  /// [body] 之后在同一 deadline 内清空微任务队列；队列清空且无异常时才提交
  /// [call] 暂存的结果。清空失败（被中断）时标记引擎为已污染。
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
      T? result;
      ScriptException? error;
      try {
        result = body();
      } on JSException catch (e) {
        error = _inspect(call, e.value);
      }
      // 被中断 / 超限：不再执行任何脚本（包括排队的微任务），引擎稍后重建。
      // 否则排在后面的短任务可能在下一次中断检查前跑完并产生宿主副作用。
      if (error?.code == ScriptException.limit) {
        _poisoned = true;
        throw error!;
      }
      try {
        _rt.drainMicrotasks();
      } on JSException catch (e) {
        _poisoned = true;
        error ??= _inspect(call, e.value);
      }
      if (error != null) throw error;
      call.commitStaged();
      return result as T;
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
    final prelude = this.prelude;
    if (prelude == null) {
      _rt.global['tsumugi'] = root.asValue;
      return;
    }
    // prelude 是受信任代码，在脚本求值之前执行；异常直接抛给调用方（属于编程错误）。
    final fn = _rt.evaluateJavascript(prelude, sourceUrl: 'tsumugi-prelude.js');
    if (!fn.isObject || !fn.asObject.isFunction) {
      throw StateError('prelude must evaluate to a function');
    }
    final api = fn.asObject.asFunction([root.asValue]);
    if (!api.isObject) throw StateError('prelude must return an object');
    api.asObject.freeze();
    _rt.global['tsumugi'] = api;
  }

  JSValue _invokeHost(HostFunction fn, List<JSValue> args) {
    final owner = _current;
    if (owner == null || owner.isDone) {
      throw JSException(
        _toJsError(const ScriptException('No active call for host function.')),
      );
    }
    final FutureOr<Object?> result;
    try {
      result = fn([for (final a in args) _toDart(a)]);
    } on Object catch (e) {
      throw JSException(_toJsError(e));
    }
    if (result is Future<Object?>) return _bridgeFuture(owner, result);
    try {
      return _toJs(result);
    } on Object catch (e) {
      throw JSException(_toJsError(e));
    }
  }

  /// 把宿主 Future 桥接成 JS Promise。resolve 时重新进入 JS，计入 CPU 预算。
  JSValue _bridgeFuture(_Call owner, Future<Object?> future) {
    final rt = _rt;
    final (promise, resolve, reject) = JSPromise.withResolvers(rt);

    void settle(JSFunction settler, JSValue Function() value) {
      if (_disposed || owner.isDone) return;
      // 调用已结束或引擎已重建：迟到的结果直接丢弃。
      if (!identical(_current, owner) || !identical(_rt, rt)) return;
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
    if (error is ScriptException) {
      if (error.code != null) {
        err.asObject['code'] = JSValue.string(_rt, error.code!);
      }
      if (error.status != null) {
        err.asObject['status'] = JSValue.number(_rt, error.status!.toDouble());
      }
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
    final rawMessage = str('message');
    final message = rawMessage ?? 'Script error';
    final stack = str('stack');

    // 引擎中断不可被脚本伪造成别的错误：最先判断。
    if (name == 'InternalError' && rawMessage == 'interrupted') {
      return call.timeLimitError(stack: stack);
    }

    // 脚本显式上报的错误码优先，不被消息文本覆盖。
    final code = str('code');
    final status = _readStatus(obj);
    if (code != null) {
      return ScriptException(message, code: code, status: status, stack: stack);
    }

    // 引擎抛出的资源超限：只认引擎的确切错误类型与消息。
    if (name == 'InternalError' && rawMessage == 'out of memory') {
      return ScriptException(
        'Memory limit exceeded (${limits.memoryBytes} bytes).',
        code: ScriptException.limit,
        stack: stack,
      );
    }
    if ((name == 'RangeError' || name == 'InternalError') &&
        rawMessage != null &&
        (rawMessage.contains('call stack') || rawMessage == 'stack overflow')) {
      return ScriptException(
        'Stack limit exceeded.',
        code: ScriptException.limit,
        stack: stack,
      );
    }
    return ScriptException(message, status: status, stack: stack);
  }

  /// 只接受 100–599 的整数。
  int? _readStatus(JSObject obj) {
    final v = obj['status'];
    if (!v.isNumber) return null;
    final n = v.asNumber;
    if (n != n.truncateToDouble() || n < 100 || n > 599) return null;
    return n.toInt();
  }
}

enum _LoadState { empty, loaded, failed }

class _Call {
  _Call(this.limits);

  final ScriptLimits limits;
  final cpu = Stopwatch();
  final wall = Stopwatch()..start();
  final _completer = Completer<Object?>();

  bool _hasStaged = false;
  Object? _staged;

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

  /// 暂存入口结果；由 [commitStaged] 在 JS 段正常结束后提交。
  void stage(Object? value) {
    if (isDone || _hasStaged) return;
    _hasStaged = true;
    _staged = value;
  }

  void commitStaged() {
    if (!_hasStaged) return;
    _hasStaged = false;
    final value = _staged;
    _staged = null;
    complete(value);
  }

  void complete(Object? value) {
    if (isDone) return;
    // 同步 JS 执行期间 Dart 计时器无法触发，完成时再核对一次总时长。
    if (wall.elapsed > limits.wallTime) {
      _completer.completeError(wallLimitError());
    } else {
      _completer.complete(value);
    }
  }

  /// 本次调用是否以资源超限（`E_LIMIT`）结束。
  bool hitLimit = false;

  void fail(ScriptException error) {
    if (isDone) return;
    hitLimit = error.code == ScriptException.limit;
    _hasStaged = false;
    _staged = null;
    _completer.completeError(error);
  }
}
