// 用于沙箱限制测试的脚本。
export async function spin() {
  for (;;) {}
}

export async function spinCaught() {
  try {
    for (;;) {}
  } catch (e) {
    return 'caught';
  }
}

export async function spinAfterAwait() {
  await tsumugi.http.get('/slow');
  for (;;) {}
}

export async function waitForever() {
  await tsumugi.http.get('/never');
}

export async function busyBetweenAwaits(rounds, ms) {
  for (let i = 0; i < rounds; i++) {
    await tsumugi.http.get('/tick');
    const end = Date.now() + ms;
    while (Date.now() < end) {}
  }
  return rounds;
}

export async function allocate() {
  const keep = [];
  for (;;) keep.push('x'.repeat(1024 * 1024) + keep.length);
}

export async function recurse() {
  const f = (n) => f(n + 1) + 1;
  return f(0);
}

export async function ok() {
  return 'ok';
}

export function throwSpinningGetter() {
  throw { get name() { for (;;) {} } };
}

export async function rejectSpinningGetter() {
  await tsumugi.http.get('/tick');
  throw { get message() { for (;;) {} } };
}

export async function returnSpinningToJSON() {
  return { toJSON() { for (;;) {} } };
}

export async function waitThenBusy(ms) {
  await tsumugi.http.get('/wait');
  const end = Date.now() + ms;
  while (Date.now() < end) {}
  return 'done';
}
