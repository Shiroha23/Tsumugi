// 被替换的内建函数在常见规模上的耗时（#29）。只定义 benchCases()，由测试拼接成脚本或模块。
// 返回 [[名称, 毫秒], ...]；每项重复足够多次，减少计时误差。

function benchCases() {
  const now = () => Date.now();
  const time = (name, reps, fn) => {
    fn();
    const start = now();
    for (let i = 0; i < reps; i++) fn();
    return [name, now() - start];
  };
  const nums = Array.from({ length: 1000 }, (_, i) => (i * 7919) % 1000);
  const words = nums.map((n) => 'item-' + n);
  const nested = Array.from({ length: 100 }, (_, i) => [i, [i + 1, i + 2], i + 3]);
  const html = ('<li class="item"><a href="/book/123">标题 123</a><span>作者</span></li>\n').repeat(150);
  return [
    time('join', 2000, () => words.join(',')),
    time('slice', 2000, () => nums.slice(100, 900)),
    time('concat', 2000, () => nums.concat(words, [1, 2, 3])),
    time('splice', 2000, () => nums.slice().splice(500, 10, 'a', 'b')),
    time('reverse', 2000, () => nums.slice().reverse()),
    time('shift/unshift', 200, () => {
      const a = nums.slice();
      for (let i = 0; i < 20; i++) a.unshift(a.shift());
    }),
    time('sort', 200, () => nums.slice().sort((a, b) => a - b)),
    time('sort strings', 200, () => words.slice().sort()),
    time('flat', 2000, () => nested.flat(2)),
    time('flatMap', 2000, () => nums.flatMap((x) => [x, x])),
    time('indexOf', 20000, () => html.indexOf('</ul>')),
    time('includes', 20000, () => html.includes('作者 999')),
    time('lastIndexOf', 20000, () => html.lastIndexOf('<li')),
    time('split', 500, () => html.split('\n')),
    time('replace', 5000, () => html.replace('/book/', '/b/')),
    time('replaceAll', 500, () => html.replaceAll('item', 'row')),
  ];
}
