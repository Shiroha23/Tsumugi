// 内建函数在大输入上的执行时间（#29）。cases 中的每个入口都应在 CPU 时间上限附近以 E_LIMIT 结束。
// 规模按“未加固时需要数秒以上”选取，测试失败时不会无限挂起。

const N = 2 ** 28;
const arrayLike = () => ({ length: N });
const holey = () => {
  const a = [];
  a.length = N;
  return a;
};
// 第一次读取 length 时很小，之后很大。
const shifting = () => {
  let reads = 0;
  return { get length() { return reads++ ? N : 0; } };
};
// 只拦截 get 的代理：length 很大，元素都不存在。
const lengthProxy = () => new Proxy([], { get: (t, k) => (k === 'length' ? N : undefined) });
const text = () => 'a'.repeat(2 ** 18);
const needle = () => 'a'.repeat(2 ** 17) + 'b';

const cases = {
  join: () => Array.prototype.join.call(arrayLike(), ''),
  holeyJoin: () => holey().join(''),
  toStringOfHoley: () => String(holey()),
  toLocaleString: () => Array.prototype.toLocaleString.call(arrayLike()),
  reverse: () => Array.prototype.reverse.call(arrayLike()),
  copyWithin: () => Array.prototype.copyWithin.call(arrayLike(), 0, 1),
  slice: () => Array.prototype.slice.call(arrayLike(), 0),
  splice: () => Array.prototype.splice.call(arrayLike(), 0, 1),
  shift: () => Array.prototype.shift.call(arrayLike()),
  unshift: () => Array.prototype.unshift.call(arrayLike(), 1),
  sort: () => Array.prototype.sort.call(arrayLike()),
  concat: () => {
    const o = arrayLike();
    o[Symbol.isConcatSpreadable] = true;
    return [].concat(o);
  },
  flat: () => Array.prototype.flat.call(arrayLike()),
  nestedFlat: () => [holey()].flat(),
  flatMap: () => Array.prototype.flatMap.call(arrayLike(), (x) => x),
  nestedFlatMap: () => [0].flatMap(() => holey()),
  // 短的真数组；读取 species / 可展开标志时把另一个参数变成很长的稀疏数组。
  speciesHookConcat: () => {
    const a = [1];
    const b = [2];
    a.constructor = { get [Symbol.species]() { b.length = N; return undefined; } };
    return a.concat(b);
  },
  spreadableHookConcat: () => {
    const b = [2];
    const c = [3];
    Object.defineProperty(c, Symbol.isConcatSpreadable, { get() { b.length = N; return true; } });
    return [1].concat(c, b);
  },
  proxyReverse: () => Array.prototype.reverse.call(lengthProxy()),
  proxyCopyWithin: () => Array.prototype.copyWithin.call(lengthProxy(), 0, 1),
  proxySplice: () => Array.prototype.splice.call(lengthProxy(), 0, 0, 1),
  indexOf: () => text().indexOf(needle()),
  indexOfStringObject: () => String.prototype.indexOf.call(new String(text()), needle()),
  includes: () => text().includes(needle()),
  lastIndexOf: () => text().lastIndexOf(needle()),
  split: () => text().split(needle()),
  replace: () => text().replace(needle(), ''),
  replaceAll: () => text().replaceAll(needle(), ''),
  convertedArgument: () => text().indexOf({ toString: needle }),
};

// length 只按第一次读取的值处理：这些入口应立即正常结束。
const quickCases = {
  shiftingJoin: () => Array.prototype.join.call(shifting()),
  shiftingReverse: () => Array.prototype.reverse.call(shifting()),
  shiftingSort: () => Array.prototype.sort.call(shifting()),
  shiftingConcat: () => {
    let reads = 0;
    const o = { get length() { return reads++ ? N : 0; } };
    Object.defineProperty(o, Symbol.isConcatSpreadable, { get: () => true });
    return [].concat(o);
  },
};

export function names() {
  return Object.keys(cases);
}

export function quickNames() {
  return Object.keys(quickCases);
}

export function run(name) {
  (cases[name] ?? quickCases[name])();
  return 'finished';
}
