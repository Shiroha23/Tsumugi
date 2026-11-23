// 内建函数行为对照（#29）：同一组输入分别在未加固的引擎与加固后的沙箱中执行，结果必须完全相同。
// 只定义 semanticCases()，由测试拼接成脚本或模块。每项结果为 { ok: 值 } 或 { err: 错误类型名 }。

function semanticCases() {
  const out = [];
  const log = [];
  const record = (label, fn) => {
    try {
      out.push([label, { ok: fn() }]);
    } catch (e) {
      out.push([label, { err: e && e.name }]);
    }
  };
  const tracked = (name, value) => ({
    toString() {
      log.push(name + ':toString');
      return value;
    },
    valueOf() {
      log.push(name + ':valueOf');
      return value;
    },
  });
  const SP = String.prototype;
  const AP = Array.prototype;

  // indexOf
  record('indexOf 1', () => 'abcabc'.indexOf('c'));
  record('indexOf 2', () => 'abcabc'.indexOf('c', 3));
  record('indexOf 3', () => 'abc'.indexOf(''));
  record('indexOf 4', () => 'abc'.indexOf('', 10));
  record('indexOf 5', () => 'abc'.indexOf('d'));
  record('indexOf 6', () => 'abc'.indexOf('a', -5));
  record('indexOf 7', () => 'abc'.indexOf('bc', NaN));
  record('indexOf 8', () => 'aaa'.indexOf('aa', 1));
  record('indexOf 9', () => 'abc'.indexOf('c', Infinity));
  record('indexOf 10', () => SP.indexOf.call(12321, 2));
  record('indexOf 11', () => SP.indexOf.call(new String('xyz'), 'z'));
  record('indexOf 12', () => SP.indexOf.call(null, 'a'));
  record('indexOf 13', () => 'abc'.indexOf(Symbol('a')));
  record('indexOf 14', () => 'abc'.indexOf('b', 1n));
  record('indexOf 15', () => 'abc'.indexOf(undefined));
  record('indexOf 16', () => 'a\u{1F600}b'.indexOf('\uDE00'));
  record('indexOf 17', () => 'abcdefabcdef'.indexOf('def', 4.9));
  record('indexOf 18', () => SP.indexOf.call(tracked('this', 'abc'), tracked('arg', 'c'), tracked('pos', 1)));
  record('indexOf 19', () => 'xxabcabc'.indexOf('abcabc'));

  // lastIndexOf
  record('lastIndexOf 1', () => 'abcabc'.lastIndexOf('c'));
  record('lastIndexOf 2', () => 'abcabc'.lastIndexOf('c', 4));
  record('lastIndexOf 3', () => 'abcabc'.lastIndexOf('c', -1));
  record('lastIndexOf 4', () => 'abcabc'.lastIndexOf('a', -1));
  record('lastIndexOf 5', () => 'abc'.lastIndexOf(''));
  record('lastIndexOf 6', () => 'abc'.lastIndexOf('', 1));
  record('lastIndexOf 7', () => 'abc'.lastIndexOf('', 10));
  record('lastIndexOf 8', () => 'abcabc'.lastIndexOf('abc', NaN));
  record('lastIndexOf 9', () => 'a'.lastIndexOf('abc'));
  record('lastIndexOf 10', () => 'aXbXc'.lastIndexOf('X', undefined));
  record('lastIndexOf 11', () => 'aaaa'.lastIndexOf('aa', 1));
  record('lastIndexOf 12', () => 'abcabc'.lastIndexOf('bc', 4.7));
  record('lastIndexOf 13', () => SP.lastIndexOf.call(undefined, 'a'));
  record('lastIndexOf 14', () => SP.lastIndexOf.call(tracked('this', 'abcb'), tracked('arg', 'b'), tracked('pos', 2)));
  record('lastIndexOf 15', () => 'abc'.lastIndexOf('c', -Infinity));

  // includes
  record('includes 1', () => 'abc'.includes('b'));
  record('includes 2', () => 'abc'.includes('b', 2));
  record('includes 3', () => 'abc'.includes(/b/));
  record('includes 4', () => 'abc'.includes({ [Symbol.match]: false, toString: () => 'b' }));
  record('includes 5', () => 'abc'.includes(''));
  record('includes 6', () => SP.includes.call(null, 'a'));
  record('includes 7', () => {
    const re = /b/;
    re[Symbol.match] = false;
    return 'a/b/c'.includes(re);
  });

  // split
  record('split 1', () => 'a,b,,c'.split(','));
  record('split 2', () => 'a,b,c'.split(',', 2));
  record('split 3', () => 'abc'.split(''));
  record('split 4', () => 'abc'.split('', 2));
  record('split 5', () => ''.split(','));
  record('split 6', () => ''.split(''));
  record('split 7', () => 'abc'.split());
  record('split 8', () => 'abc'.split(undefined, 0));
  record('split 9', () => 'abc'.split('abc'));
  record('split 10', () => ',a,'.split(','));
  record('split 11', () => 'aaa'.split('aa'));
  record('split 12', () => 'a,b'.split(',', -1));
  record('split 13', () => 'a,b,c'.split(',', 1.5));
  record('split 14', () => 'a1b1c'.split(1));
  record('split 15', () => 'a-b'.split({ toString: () => '-' }));
  record('split 16', () => 'a-b'.split({ [Symbol.split]: (s, l) => ['custom', s, l] }, 3));
  record('split 17', () => 'a-b'.split({ [Symbol.split]: 1 }));
  record('split 18', () => 'a-b-c'.split(/-/));
  record('split 19', () => SP.split.call(null, ','));
  record('split 20', () => 'abab'.split('ab'));
  record('split 21', () => 'a,b'.split(',', 2 ** 32 + 1));
  record('split 22', () => SP.split.call(tracked('this', 'a,b'), tracked('sep', ','), tracked('lim', 5)));
  record('split 23', () => 'x'.split('xyz'));

  // replace
  record('replace 1', () => 'abc'.replace('b', 'x'));
  record('replace 2', () => 'abcb'.replace('b', '[$&]'));
  record('replace 3', () => 'abc'.replace('b', "$`|$'"));
  record('replace 4', () => 'abc'.replace('b', '$$'));
  record('replace 5', () => 'abc'.replace('b', '$1$<n>$0$01$'));
  record('replace 6', () => 'abc'.replace('b', '$'));
  record('replace 7', () => 'abc'.replace('d', 'x'));
  record('replace 8', () => 'abc'.replace('', 'x'));
  record('replace 9', () => 'abc'.replace('c', "$'|$`"));
  record('replace 10', () => {
    const args = [];
    const r = 'xabcx'.replace('abc', (...a) => {
      args.push(a);
      return 7;
    });
    return [r, args];
  });
  record('replace 11', () => 'abc'.replace('b', 5));
  record('replace 12', () => 'abc'.replace({ toString: () => 'c' }, 'Z'));
  record('replace 13', () => 'abcb'.replace(/b/g, 'Y'));
  record('replace 14', () => 'abc'.replace({ [Symbol.replace]: (s, v) => [s, v] }, 'q'));
  record('replace 15', () => SP.replace.call(null, 'a', 'b'));
  record('replace 16', () => 'a$b'.replace('$', '$$$$'));
  record('replace 17', () => 'abc'.replace(undefined, 'x'));
  record('replace 18', () => 'undefined!'.replace(undefined, 'x'));
  record('replace 19', () => SP.replace.call(tracked('this', 'abc'), tracked('search', 'b'), tracked('value', 'X')));

  // replaceAll
  record('replaceAll 1', () => 'abab'.replaceAll('b', 'x'));
  record('replaceAll 2', () => 'aaaa'.replaceAll('aa', 'b'));
  record('replaceAll 3', () => 'abc'.replaceAll('', '-'));
  record('replaceAll 4', () => 'abc'.replaceAll('', '[$&]'));
  record('replaceAll 5', () => {
    const args = [];
    const r = 'abab'.replaceAll('b', (...a) => {
      args.push(a);
      return a[1];
    });
    return [r, args];
  });
  record('replaceAll 6', () => 'abc'.replaceAll(/b/, 'x'));
  record('replaceAll 7', () => 'abcb'.replaceAll(/b/g, 'x'));
  record('replaceAll 8', () => 'aaa'.replaceAll('a', "$'"));
  record('replaceAll 9', () => 'xyx'.replaceAll('x', '$`'));
  record('replaceAll 10', () => 'abc'.replaceAll('d', 'x'));
  record('replaceAll 11', () => ''.replaceAll('', 'x'));
  record('replaceAll 12', () => 'abc'.replaceAll({ [Symbol.match]: true, flags: 'i', [Symbol.replace]: () => 'r' }, 'x'));
  record('replaceAll 13', () => 'abc'.replaceAll({ [Symbol.match]: true, flags: 'gi', [Symbol.replace]: () => 'r' }, 'x'));
  record('replaceAll 14', () => 'abc'.replaceAll({ [Symbol.match]: true, flags: undefined }, 'x'));
  record('replaceAll 15', () => SP.replaceAll.call(tracked('this', 'abab'), tracked('search', 'a'), tracked('value', '-')));
  record('replaceAll 16', () => 'a.b.c'.replaceAll('.', '$&$&'));

  // flat / flatMap
  record('flat 1', () => [1, [2, [3, [4]]]].flat());
  record('flat 2', () => [1, [2, [3, [4]]]].flat(2));
  record('flat 3', () => [1, [2, [3, [4]]]].flat(Infinity));
  record('flat 4', () => [1, [2, [3]]].flat(0));
  record('flat 5', () => [1, [2, [3]]].flat(-1));
  record('flat 6', () => [1, , [2, , 3]].flat());
  record('flat 7', () => AP.flat.call({ length: 2, 0: [1], 1: 2 }));
  record('flat 8', () => AP.flat.call('ab'));
  record('flat 9', () => {
    class A extends Array {}
    const r = A.from([1, [2]]).flat();
    return [r instanceof A, Array.from(r)];
  });
  record('flat 10', () => AP.flat.call(null));
  record('flat 11', () => [[1], [[2]]].flat('1'));
  record('flat 12', () => {
    const a = [1, [2]];
    a.constructor = { [Symbol.species]: null };
    return a.flat();
  });
  record('flat 13', () => {
    const a = [1, [2]];
    a.constructor = { [Symbol.species]: 5 };
    return a.flat();
  });
  record('flat 14', () => [{ length: 1, 0: 'x' }, [[]]].flat(2));
  record('flatMap 1', () => [1, 2].flatMap((x) => [x, [x]]));
  record('flatMap 2', () => [1, 2].flatMap(function (x, i, a) { return [this.k, x, i, a.length]; }, { k: 'k' }));
  record('flatMap 3', () => [1].flatMap(5));
  record('flatMap 4', () => [1, , 3].flatMap((x) => x));
  record('flatMap 5', () => AP.flatMap.call({ length: 2, 0: 'a', 1: 'b' }, (x) => [x, x]));

  // 加固时包了一层的数组方法：小输入上行为不变
  record('array 1', () => [3, 1, 2].sort());
  record('array 2', () => [3, 1, 2].sort((a, b) => b - a));
  record('array 3', () => [1, 2, 3].reverse());
  record('array 4', () => [1, 2, 3, 4, 5].copyWithin(0, 3));
  record('array 5', () => [1, 2, 3].slice(1));
  record('array 6', () => {
    const a = [1, 2, 3];
    return [a.splice(1, 1, 'x', 'y'), a];
  });
  record('array 7', () => {
    const a = [1, 2];
    return [a.shift(), a.unshift(0, 0), a];
  });
  record('array 8', () => [1, [2, 3]].join('-'));
  record('array 9', () => String([1, [2, 3], null, undefined]));
  record('array 10', () => [1, 2].concat([3], 4, [[5]]));
  record('array 11', () => {
    const o = { length: 2, 0: 'a', 1: 'b', [Symbol.isConcatSpreadable]: true };
    return [0].concat(o);
  });
  record('array 12', () => AP.join.call({ length: 3, 0: 'x', 2: 'z' }, '+'));
  record('array 13', () => AP.sort.call([2, 1], 'bad'));
  record('array 14', () => AP.join.call(null));
  record('array 15', () => [1, 2].toLocaleString());
  record('array 16', () => AP.concat.call(1, 2));
  record('array 17', () => AP.slice.call('abc', 1));

  // 经代理记录每一步的属性访问：操作序列（含 length 的读取次数）必须与原生实现相同。
  const trace = (target, fn) => {
    const ops = [];
    const key = (k) => (typeof k === 'symbol' ? k.toString() : k);
    const p = new Proxy(target, {
      get(t, k, r) { ops.push(['get', key(k)]); return Reflect.get(t, k, r); },
      set(t, k, v, r) { ops.push(['set', key(k), v]); return Reflect.set(t, k, v, r); },
      has(t, k) { ops.push(['has', key(k)]); return Reflect.has(t, k); },
      deleteProperty(t, k) { ops.push(['delete', key(k)]); return Reflect.deleteProperty(t, k); },
      defineProperty(t, k, d) { ops.push(['define', key(k)]); return Reflect.defineProperty(t, k, d); },
    });
    let result;
    try {
      result = fn(p);
      if (result === p) result = 'self';
    } catch (e) {
      result = 'throws ' + e.name;
    }
    return [result, ops, Array.from(target)];
  };
  const holeyTarget = () => [1, , 3, , 5];
  record('trace join', () => trace(holeyTarget(), (p) => AP.join.call(p, '-')));
  record('trace toLocaleString', () => trace([1, null, 'x'], (p) => AP.toLocaleString.call(p)));
  record('trace reverse', () => trace(holeyTarget(), (p) => AP.reverse.call(p)));
  record('trace reverse even', () => trace([1, , , 4], (p) => AP.reverse.call(p)));
  record('trace copyWithin', () => trace(holeyTarget(), (p) => AP.copyWithin.call(p, 0, 2)));
  record('trace copyWithin back', () => trace(holeyTarget(), (p) => AP.copyWithin.call(p, 2, 0, 3)));
  record('trace copyWithin neg', () => trace(holeyTarget(), (p) => AP.copyWithin.call(p, -2, -4, -1)));
  record('trace slice', () => trace(holeyTarget(), (p) => AP.slice.call(p, 1, -1)));
  record('trace splice delete', () => trace(holeyTarget(), (p) => AP.splice.call(p, 1, 2)));
  record('trace splice insert', () => trace(holeyTarget(), (p) => AP.splice.call(p, 1, 1, 'a', 'b', 'c')));
  record('trace splice same', () => trace(holeyTarget(), (p) => AP.splice.call(p, 2, 1, 'z')));
  record('trace splice none', () => trace(holeyTarget(), (p) => AP.splice.call(p)));
  record('trace splice start', () => trace(holeyTarget(), (p) => AP.splice.call(p, -2)));
  record('trace shift', () => trace(holeyTarget(), (p) => AP.shift.call(p)));
  record('trace shift empty', () => trace([], (p) => AP.shift.call(p)));
  record('trace unshift', () => trace(holeyTarget(), (p) => AP.unshift.call(p, 'a', 'b')));
  record('trace unshift none', () => trace(holeyTarget(), (p) => AP.unshift.call(p)));
  record('trace sort', () => trace([3, , 1, undefined, 2], (p) => AP.sort.call(p)));
  record('trace sort cmp', () => trace([3, , 1, 2], (p) => AP.sort.call(p, (a, b) => a - b)));
  record('trace concat', () => trace(holeyTarget(), (p) => AP.concat.call([0], p, 9)));
  record('trace concat self', () => trace(holeyTarget(), (p) => AP.concat.call(p, [7])));
  record('trace flat', () => trace([1, [2, , 3], , 4], (p) => AP.flat.call(p)));
  record('trace flatMap', () => trace([1, , 2], (p) => AP.flatMap.call(p, (x) => [x, x])));
  record('splice near max', () => {
    const o = { length: 2 ** 53 - 1 };
    try {
      AP.splice.call(o, 2 ** 53 - 2, 1, 'a', 'b');
    } catch (e) {
      return [e.name, Object.keys(o)];
    }
    return ['no error', Object.keys(o), o.length];
  });
  record('splice at max', () => {
    const o = { length: 2 ** 53 - 1 };
    AP.splice.call(o, 2 ** 53 - 2, 1, 'a');
    return [Object.keys(o), o.length];
  });
  record('unshift near max', () => AP.unshift.call({ length: 2 ** 53 - 1 }, 1));
  record('concat near max', () => {
    const o = { length: 2 ** 53 - 1, [Symbol.isConcatSpreadable]: true };
    return AP.concat.call([], [1], o).length;
  });
  record('trace frozen', () => trace(Object.freeze([1, 2]), (p) => AP.reverse.call(p)));
  record('length reads', () => {
    let reads = 0;
    const make = () => ({ get length() { reads++; return 2; }, 0: 'b', 1: 'a' });
    const counts = [];
    for (const name of ['join', 'toLocaleString', 'reverse', 'copyWithin', 'slice', 'splice',
      'shift', 'unshift', 'sort', 'concat', 'flat', 'flatMap']) {
      reads = 0;
      const o = make();
      if (name === 'concat') o[Symbol.isConcatSpreadable] = true;
      try {
        if (name === 'concat') AP.concat.call([], o);
        else if (name === 'flatMap') AP.flatMap.call(o, (x) => x);
        else AP[name].call(o, 0);
      } catch (e) {
        counts.push(name + ' ' + e.name);
      }
      counts.push(name + ' ' + reads);
    }
    return counts;
  });

  // 函数对象本身的属性
  const fnInfo = (proto, name) => {
    const d = Object.getOwnPropertyDescriptor(proto, name);
    const f = d.value;
    return [name, f.name, f.length, d.writable, d.enumerable, d.configurable,
      Object.prototype.hasOwnProperty.call(f, 'prototype'), typeof f];
  };
  for (const name of ['join', 'toLocaleString', 'reverse', 'copyWithin', 'slice', 'splice',
    'shift', 'unshift', 'sort', 'concat', 'flat', 'flatMap']) {
    record('fn ' + name, () => fnInfo(AP, name));
    record('new ' + name, () => new AP[name]());
  }
  for (const name of ['indexOf', 'lastIndexOf', 'includes', 'split', 'replace', 'replaceAll']) {
    record('fn ' + name, () => fnInfo(SP, name));
    record('new ' + name, () => new SP[name]());
  }

  out.push(['conversion order', { ok: log }]);
  return out;
}
