import 'dart:ffi';

import 'package:qjs/qjs.dart';

/// QuickJS-ng 的 `JS_UpdateStackTop`，由 `package:qjs` 的原生库导出（未在其 Dart API 中暴露）。
@Native<Void Function(Pointer<Void>)>(
  symbol: 'JS_UpdateStackTop',
  assetId: 'package:qjs/qjs.dart',
)
external void _jsUpdateStackTop(Pointer<Void> rt);

/// 把 QuickJS 的栈顶记录更新为当前线程的栈指针。
///
/// QuickJS 只在创建 `JSRuntime` 时记录一次栈顶，之后按“栈顶 − maxStackSize”检查栈溢出。
/// Dart isolate 在两个事件之间可能被调度到线程池中的另一个 OS 线程上，
/// 此时旧的栈顶属于别的线程：要么每次调用都误报 `Maximum call stack size exceeded`，
/// 要么栈检查完全失效（深递归会让原生栈溢出、进程崩溃）。worker isolate 中已实测到前者。
/// 因此每次从 Dart 同步进入 JS 之前都要调用一次（docs/architecture.md §6.1）。
void updateStackTop(JSRuntime rt) =>
    _jsUpdateStackTop(nativeRuntimePointer(rt));

/// `package:qjs` 的运行时包装背后的 QuickJS `JSRuntime *`。
///
/// `QJSABIRuntime` 的第一个字段是 `JSRuntime *rt`（qjs `src/qjs_dart.c`）。
/// `ptr` 在 qjs 中标为 @internal：这是在上游公开更新栈顶的 API 之前的临时做法。
/// qjs 已在 `pubspec.yaml` 中固定版本，升级时须复查结构布局，
/// `test/core/engine/script/native_stack_test.dart` 会在布局失效时失败（#28）。
Pointer<Void> nativeRuntimePointer(JSRuntime rt) {
  // ignore: invalid_use_of_internal_member
  return Pointer<Pointer<Void>>.fromAddress(rt.ptr.address).value;
}
