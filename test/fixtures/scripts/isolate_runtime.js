// IsolateScriptRuntime 测试用的脚本（test/core/engine/script/isolate_script_runtime_test.dart）。
// tsumugi.test.* 由测试的 worker 宿主实现：spin(ms) 在 worker 的 Dart 代码里忙等，
// 模拟不能被中断的执行；flag() 表示测试是否要求模块加载时卡住。

if (tsumugi.test.flag()) tsumugi.test.spin(1500);

let counter = 0;
export async function add(a, b) { return a + b; }
export async function bump() { return ++counter; }
export async function remote(x) { return await tsumugi.echo.async(x); }
export function sync(x) { return tsumugi.echo.sync(x); }
export async function remoteError() {
  try { await tsumugi.echo.fail(); } catch (e) { return [e.code, e.status, e.message]; }
}
export function notify() { return tsumugi.log.info('hi', 1) == null; }
export function calls() { return tsumugi.test.calls(); }
export function loop() { for (;;) {} }
export function spin(ms) { tsumugi.test.spin(ms); }
export async function crash() {
  tsumugi.test.crash();
  return await tsumugi.echo.slow();
}
export async function slowRemote() { return await tsumugi.echo.slow(); }
export async function crashLater() {
  tsumugi.test.spin(300);
  return await tsumugi.echo.slow();
}
