import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qjs/qjs.dart';
import 'package:tsumugi/core/engine/script/native_stack.dart';

/// 只在测试中使用：通过同一个指针修改栈上限，用来确认指针确实指向这个运行时。
@Native<Void Function(Pointer<Void>, Size)>(
  symbol: 'JS_SetMaxStackSize',
  assetId: 'package:qjs/qjs.dart',
)
external void _jsSetMaxStackSize(Pointer<Void> rt, int stackSize);

final _depth = File('test/fixtures/scripts/stack_depth.js').readAsStringSync();

/// `native_stack.dart` 读取 `package:qjs` 内部的 `JSRuntime.ptr` 布局（#28）。
/// 升级 qjs 后布局一旦变化，`nativeRuntimePointer` 就不再指向真正的 QuickJS 运行时，这里会失败。
///
/// 线程迁移导致的误报本身无法在测试中稳定复现，所以改为确定性地检查指针：
/// 经该指针设置的栈上限必须真的作用于 JS 的递归。
void main() {
  late JSRuntime rt;

  setUp(() {
    rt = JSRuntime.create(
      const JSRuntimeConfig(enableEval: false, maxStackSize: 512 * 1024),
    );
    updateStackTop(rt);
    rt.evaluateJavascript(_depth);
  });

  tearDown(() => rt.release());

  /// 512 KB 上限下能完成的最大递归深度（按 2 倍递增探测，结果至少是真实上限的一半）。
  /// 每层原生栈帧的大小随构建方式变化很大，所以不写死深度。
  int maxDepth() {
    var ok = 0;
    for (var n = 8; n <= 1 << 16; n *= 2) {
      try {
        rt.evaluateJavascript('depth($n)');
        ok = n;
      } on JSException {
        break;
      }
    }
    return ok;
  }

  test('nativeRuntimePointer points at the QuickJS runtime', () {
    final n = maxDepth();
    expect(n, greaterThan(0));
    expect(rt.evaluateJavascript('depth($n)').asNumber, n);

    // 经该指针把上限缩到 1/32：探测到的深度至少用掉 256 KB，必然放不下。
    // 指针若指向别处，真实上限不变，这次递归仍会成功。
    _jsSetMaxStackSize(nativeRuntimePointer(rt), 16 * 1024);
    updateStackTop(rt);
    expect(
      () => rt.evaluateJavascript('depth($n)'),
      throwsA(isA<JSException>()),
    );

    // 恢复上限后同一运行时仍可正常递归。
    _jsSetMaxStackSize(nativeRuntimePointer(rt), 512 * 1024);
    updateStackTop(rt);
    expect(rt.evaluateJavascript('depth($n)').asNumber, n);
  });

  test('pointer is stable for the lifetime of the runtime', () {
    expect(nativeRuntimePointer(rt), isNot(nullptr));
    expect(nativeRuntimePointer(rt), nativeRuntimePointer(rt));
  });
}
