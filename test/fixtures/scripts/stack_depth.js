// 用于 native_stack_test.dart 的普通脚本（非模块）：按指定深度递归。
function depth(n) {
  return n === 0 ? 0 : 1 + depth(n - 1);
}
