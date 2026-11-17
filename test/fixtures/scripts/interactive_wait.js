// 用于“交互式宿主调用不计入总时长”测试（#23，source-spec §4.4）的脚本。
// tsumugi.ui.openWebView(ms) 由测试宿主实现为等待 ms 毫秒；tsumugi.http.wait(ms) 为普通的慢请求。

export async function login(ms) {
  await tsumugi.ui.openWebView(ms);
  return 'ok';
}

export async function slowThenLogin(before, ms, after) {
  await tsumugi.http.wait(before);
  await tsumugi.ui.openWebView(ms);
  await tsumugi.http.wait(after);
  return 'ok';
}

export async function loginTwice(ms) {
  await tsumugi.ui.openWebView(ms);
  await tsumugi.ui.openWebView(ms);
  return 'ok';
}

export async function loginFails(ms, after) {
  try {
    await tsumugi.ui.openWebView(-ms);
  } catch (e) {
    await tsumugi.http.wait(after);
    return e.code;
  }
  return 'no error';
}

// 交互调用进行中时并发普通请求：普通请求在等待期间照常计总时长。
export async function loginAlongside(ms, plain) {
  await Promise.all([tsumugi.ui.openWebView(ms), tsumugi.http.wait(plain)]);
  return 'ok';
}

// 两个并发的交互调用：共用同一份交互等待预算。
export async function loginConcurrently(a, b) {
  await Promise.all([tsumugi.ui.openWebView(a), tsumugi.ui.openWebView(b)]);
  return 'ok';
}

// 交互调用进行中时 worker 卡在宿主 Dart 代码里（QuickJS 的中断不起作用）。
export async function hangDuringLogin(ms, spin) {
  const p = tsumugi.ui.openWebView(ms);
  tsumugi.test.spin(spin);
  await p;
  return 'ok';
}

// 交互结束之后 worker 才卡住。
export async function hangAfterLogin(ms, spin) {
  await tsumugi.ui.openWebView(ms);
  tsumugi.test.spin(spin);
  return 'ok';
}

// 交互等待期间脚本继续执行 CPU 密集代码：CPU 预算照常有效。
export async function spinDuringLogin(ms) {
  const p = tsumugi.ui.openWebView(ms);
  await tsumugi.http.wait(0);
  for (;;) {}
  await p;
}
