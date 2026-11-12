import '../script/script_runtime.dart';

/// `js:` 步骤的求值器。
abstract interface class JsEvaluator {
  /// 计算 JS 表达式 [code]，其中 `result` 绑定为上一步的值（JSON 兼容值）。
  /// 失败时抛出异常（由调用方记录日志并视为空值）。
  Future<Object?> evaluate(String code, Object? result);
}

/// 基于 [ScriptRuntime] 的 [JsEvaluator]：一个源的所有 `js:` 片段在同一个沙箱中执行。
///
/// 运行时禁用了 `eval` / `Function`，所以片段不能在运行时动态编译；
/// 构造时需给出该源用到的全部片段，首次求值时把它们编译成一个模块：
///
/// ```js
/// const f = [(result) => (/* 片段 0 */), ...];
/// export function run(i, result) { return f[i](result); }
/// ```
///
/// 某个片段有语法错误时整个模块会加载失败；此时逐个检查片段，剔除有错误的再加载，
/// 有错误的片段求值时抛出 [ScriptException]。
class ScriptJsEvaluator implements JsEvaluator {
  ScriptJsEvaluator(
    this._factory,
    Iterable<String> snippets, {
    this.limits = const ScriptLimits(),
  }) : _snippets = snippets.toSet().toList();

  final ScriptRuntimeFactory _factory;
  final List<String> _snippets;
  final ScriptLimits limits;

  ScriptRuntime? _runtime;
  Future<void>? _loading;
  final _index = <String, int>{};
  final _broken = <String, String>{};
  bool _disposed = false;

  @override
  Future<Object?> evaluate(String code, Object? result) async {
    if (_disposed) throw StateError('ScriptJsEvaluator 已释放');
    await (_loading ??= _load());
    final broken = _broken[code];
    if (broken != null) throw ScriptException(broken);
    final i = _index[code];
    if (i == null) throw ScriptException('未注册的 js 片段: $code');
    return _runtime!.call('run', [i, result]);
  }

  Future<void> _load() async {
    var good = _snippets;
    try {
      _runtime = await _tryLoad(good);
    } on ScriptException {
      // 找出有语法错误的片段。
      good = [];
      for (final s in _snippets) {
        final probe = _factory(host: const {}, limits: limits);
        try {
          await probe.load(_module([s]), name: 'js-probe.js');
          good.add(s);
        } on ScriptException catch (e) {
          _broken[s] = e.message;
        } finally {
          probe.dispose();
        }
      }
      _runtime = await _tryLoad(good);
    }
    for (var i = 0; i < good.length; i++) {
      _index[good[i]] = i;
    }
  }

  Future<ScriptRuntime> _tryLoad(List<String> snippets) async {
    final rt = _factory(host: const {}, limits: limits);
    try {
      await rt.load(_module(snippets), name: 'declarative-js.js');
      return rt;
    } catch (_) {
      rt.dispose();
      rethrow;
    }
  }

  static String _module(List<String> snippets) {
    final b = StringBuffer('const f = [\n');
    for (final s in snippets) {
      // 换行包裹，避免片段末尾的 `//` 注释吞掉右括号。
      b.write('(result) => (\n$s\n),\n');
    }
    b.write('];\n');
    b.write('export function run(i, result) { return f[i](result); }\n');
    return b.toString();
  }

  void dispose() {
    _disposed = true;
    _runtime?.dispose();
    _runtime = null;
  }
}
