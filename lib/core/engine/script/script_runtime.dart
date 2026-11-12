/// 脚本引擎（docs/source-spec.md §4）的运行时抽象。
///
/// 规则引擎只依赖这里的接口，不直接接触具体的 JS 引擎绑定，
/// 以便在某个平台不可用时替换实现（例如 iOS 换成 JavaScriptCore）。
///
/// 跨边界的值一律是 JSON 兼容的 Dart 值：
/// `null` / `bool` / `num` / `String` / `List<Object?>` / `Map<String, Object?>`。
library;

import 'dart:async';

/// 宿主函数：由 Dart 实现、暴露给脚本的能力。
///
/// - 返回 [Future] 时，脚本侧得到 Promise：Future 完成时 resolve，失败时 reject。
/// - 返回普通值时，脚本侧同步得到该值（如 `tsumugi.crypto.md5`）；抛出异常即 JS 异常。
///
/// [ScriptException] 的 `code` 会保留在 JS 错误对象的 `code` 属性上。
typedef HostFunction = FutureOr<Object?> Function(List<Object?> args);

/// 沙箱限制，默认值见 docs/source-spec.md §4.4。
class ScriptLimits {
  const ScriptLimits({
    this.cpuTime = const Duration(seconds: 5),
    this.wallTime = const Duration(seconds: 30),
    this.memoryBytes = 64 * 1024 * 1024,
    this.maxStackBytes = 512 * 1024,
  });

  /// 单次入口调用中，脚本实际执行（不含等待宿主 Future）的累计时长上限。
  final Duration cpuTime;

  /// 单次入口调用的总时长上限（含网络等待）。
  final Duration wallTime;

  /// JS 堆内存上限（整个运行时共享）。
  final int memoryBytes;

  /// JS 调用栈上限。
  final int maxStackBytes;
}

/// 脚本执行失败。`code` 取自 docs/source-spec.md §6 的错误码；
/// 普通的未捕获 JS 异常 `code` 为 `null`。
class ScriptException implements Exception {
  const ScriptException(this.message, {this.code, this.status, this.stack});

  static const limit = 'E_LIMIT';
  static const unsupported = 'E_UNSUPPORTED';

  final String? code;
  final String message;

  /// HTTP 状态码，通常随 `E_HTTP` 一起出现（100–599）。
  ///
  /// 在宿主与脚本之间双向保留：宿主抛出时脚本可读 `e.status`，
  /// 脚本抛出 `{ code, status }` 时 Dart 侧可读此字段。
  final int? status;
  final String? stack;

  @override
  String toString() =>
      'ScriptException(${code ?? 'E_SCRIPT'}'
      '${status == null ? '' : ' $status'}): $message'
      '${stack == null ? '' : '\n$stack'}';
}

/// 一个已加载源脚本的运行时实例。一个源对应一个实例，互不共享状态。
abstract interface class ScriptRuntime {
  /// 以 ES 模块方式加载源脚本。每个实例只能加载一次；
  /// 加载失败后实例不可再用（再次 [load] 或 [call] 抛出 [StateError]），需新建实例。
  Future<void> load(String source, {String name = 'source.js'});

  /// 调用模块导出的（异步）函数，返回其 resolve 的值。
  ///
  /// - 导出不存在时抛出 `code == E_UNSUPPORTED` 的 [ScriptException]。
  /// - 超出 [ScriptLimits] 时抛出 `code == E_LIMIT` 的 [ScriptException]。
  Future<Object?> call(String export, [List<Object?> args = const []]);

  /// 释放引擎资源。之后不可再使用。
  void dispose();
}

/// 创建 [ScriptRuntime] 的工厂，由具体实现提供。
///
/// [host] 是宿主 API 的扁平表，键为点分路径（如 `http.get`），
/// 会挂到脚本全局的 `tsumugi` 对象上。只允许注册 source-spec §4.2 中列出的 API。
typedef ScriptRuntimeFactory = ScriptRuntime Function({
  required Map<String, HostFunction> host,
  ScriptLimits limits,
});
