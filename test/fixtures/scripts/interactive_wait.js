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

// 交互调用进行中时并发一个永不结束的普通请求：交互结束后总时长恢复，调用最终仍会超时。
export async function loginAlongsideHang(ms) {
  await Promise.all([tsumugi.ui.openWebView(ms), tsumugi.http.wait(-1)]);
  return 'unreachable';
}

// 交互等待期间脚本继续执行 CPU 密集代码：CPU 预算照常有效。
export async function spinDuringLogin(ms) {
  const p = tsumugi.ui.openWebView(ms);
  await tsumugi.http.wait(0);
  for (;;) {}
  await p;
}
