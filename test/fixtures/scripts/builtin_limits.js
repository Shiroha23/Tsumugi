// 内建函数在大输入上的执行时间（#29）。每个入口都应在 CPU 时间上限附近以 E_LIMIT 结束。
// 规模按“未加固时需要数秒以上”选取，测试失败时不会无限挂起。

const N = 2 ** 28;
const arrayLike = () => ({ length: N });
const holey = () => {
  const a = [];
  a.length = N;
  return a;
};
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
  indexOf: () => text().indexOf(needle()),
  indexOfStringObject: () => String.prototype.indexOf.call(new String(text()), needle()),
  includes: () => text().includes(needle()),
  lastIndexOf: () => text().lastIndexOf(needle()),
  split: () => text().split(needle()),
  replace: () => text().replace(needle(), ''),
  replaceAll: () => text().replaceAll(needle(), ''),
  convertedArgument: () => text().indexOf({ toString: needle }),
};

export function names() {
  return Object.keys(cases);
}

export function run(name) {
  cases[name]();
  return 'finished';
}
