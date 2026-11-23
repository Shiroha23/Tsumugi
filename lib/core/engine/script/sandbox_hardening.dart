/// 沙箱的内建函数加固（#29，docs/architecture.md §6.1）。
///
/// QuickJS 只在执行字节码、调用函数等“检查点”上检查中断 deadline，少数原生内建函数的内部循环
/// 不经过检查点，遇到极端输入时 CPU / 总时长限制对它们无效。这里在脚本求值之前，用受信任的 JS
/// 替换这些内建函数：
///
/// - 按 `length` 逐项处理的数组方法（`join`、`toLocaleString`、`reverse`、`copyWithin`、`slice`、
///   `splice`、`shift`、`unshift`、`sort`、`concat`、`flat`、`flatMap`）：改为按规范逐步执行的 JS 实现，
///   `length` 只读一次，每一步都经过中断检查点。行为与标准一致。
/// - 字符串子串查找（`indexOf` / `lastIndexOf` / `includes` / `split` / `replace` / `replaceAll`
///   的字符串参数路径）：工作量（两串长度之积）不超过 [SandboxHardening.maxSearchWork] 时
///   直接调用原生实现，否则改用按块比较的 JS 实现，结果与原生一致。
///
/// 替换后的函数只引用加固代码自己保存的原生函数，脚本事后篡改原型不影响它们；
/// 不新增任何全局对象或宿主 API。
library;

/// 加固参数。
class SandboxHardening {
  const SandboxHardening({this.maxSearchWork = 1 << 24});

  /// 字符串查找直接走原生实现的最大工作量（被查找串剩余长度 × 模式串长度）。
  final int maxSearchWork;

  /// 返回在脚本之前执行的受信任 JS（一段脚本，执行结果为 `undefined`）。
  String get script =>
      _script.replaceAll('__MAX_SEARCH_WORK__', '$maxSearchWork');
}

const _script = r'''
(() => {
  'use strict';
  const MAX_WORK = __MAX_SEARCH_WORK__;
  const CHUNK = 4096;

  const Obj = Object;
  const Arr = Array;
  const TypeErr = TypeError;
  const apply = Reflect.apply;
  const construct = Reflect.construct;
  const ProxyCtor = Proxy;
  const defineProperty = Obj.defineProperty;
  const getOwnPropertyDescriptor = Obj.getOwnPropertyDescriptor;
  const isArray = Arr.isArray;
  const trunc = Math.trunc;
  const symMatch = Symbol.match;
  const symSplit = Symbol.split;
  const symReplace = Symbol.replace;
  const symSpecies = Symbol.species;
  const symSpreadable = Symbol.isConcatSpreadable;
  const AP = Arr.prototype;
  const SP = String.prototype;
  const RP = RegExp.prototype;
  const regexpSource = getOwnPropertyDescriptor(RP, 'source').get;
  const nIndexOf = SP.indexOf;
  const nLastIndexOf = SP.lastIndexOf;
  const nStartsWith = SP.startsWith;
  const nSlice = SP.slice;

  const isObject = (v) => (typeof v === 'object' && v !== null) || typeof v === 'function';
  const toObject = (v) => {
    if (v == null) throw new TypeErr('Cannot convert undefined or null to object');
    return Obj(v);
  };
  const requireCoercible = (v) => {
    if (v == null) throw new TypeErr('String.prototype method called on null or undefined');
    return v;
  };
  // ToString：模板字符串按 ToString 语义转换（Symbol 抛 TypeError）。
  const toStr = (v) => `${v}`;
  const toIntegerOrInfinity = (v) => {
    const n = +v;
    if (n !== n) return 0;
    return trunc(n) + 0;
  };
  const toLength = (v) => {
    const n = toIntegerOrInfinity(v);
    if (n <= 0) return 0;
    return n < 9007199254740991 ? n : 9007199254740991;
  };
  const toUint32 = (v) => {
    const n = +v;
    if (n !== n || n === Infinity || n === -Infinity) return 0;
    return trunc(n) >>> 0;
  };
  const getMethod = (v, key) => {
    const f = v[key];
    if (f == null) return undefined;
    if (typeof f !== 'function') throw new TypeErr('not a function');
    return f;
  };
  const isRegExp = (v) => {
    if (!isObject(v)) return false;
    const m = v[symMatch];
    if (m !== undefined) return !!m;
    if (v === RP) return false;
    try {
      apply(regexpSource, v, []);
      return true;
    } catch {
      return false;
    }
  };
  // IsConstructor：经代理的 construct 陷阱探测，不读取 f 的任何属性。
  const probeHandler = { __proto__: null, construct: () => probeHandler };
  const isConstructor = (f) => {
    if (typeof f !== 'function') return false;
    try {
      new (new ProxyCtor(f, probeHandler))();
      return true;
    } catch {
      return false;
    }
  };
  // 不受 Object.prototype 上的 get / set 影响的数据属性描述符。
  const dataDesc = (value) => ({
    __proto__: null, value, writable: true, enumerable: true, configurable: true,
  });
  const slice = (s, a, b) => apply(nSlice, s, [a, b]);

  const install = (proto, name, fn, arity) => {
    defineProperty(fn, 'name', { __proto__: null, value: name, configurable: true });
    defineProperty(fn, 'length', { __proto__: null, value: arity, configurable: true });
    defineProperty(proto, name, {
      __proto__: null, value: fn, writable: true, enumerable: false, configurable: true,
    });
  };

  // --- 数组 -------------------------------------------------------------------
  // 按 ECMA-262 §23.1.3 逐步实现：length 只读一次，逐项处理（每步都经过中断检查点）。
  // 只在客户端私有、原型为 null 的稠密数组上调用原生 sort，其长度受内存上限约束。

  const MAX_SAFE = 9007199254740991;
  const setPrototypeOf = Obj.setPrototypeOf;
  const nSort = AP.sort;
  const privateArray = () => {
    const a = [];
    setPrototypeOf(a, null);
    return a;
  };
  const relIndex = (v, len) => {
    const r = toIntegerOrInfinity(v);
    if (r < 0) return len + r > 0 ? len + r : 0;
    return r < len ? r : len;
  };
  const lengthOf = (o) => toLength(o.length);

  const joinItems = (o, len, sep, locale) => {
    let r = '';
    for (let k = 0; k < len; k++) {
      if (k > 0) r += sep;
      let e = o[k];
      if (e == null) continue;
      if (locale) {
        const f = e.toLocaleString;
        e = apply(f, e, []);
      }
      r += toStr(e);
    }
    return r;
  };
  install(AP, 'join', {
    join(separator) {
      const o = toObject(this);
      const len = lengthOf(o);
      const sep = separator === undefined ? ',' : toStr(separator);
      return joinItems(o, len, sep, false);
    },
  }.join, 1);
  install(AP, 'toLocaleString', {
    toLocaleString() {
      const o = toObject(this);
      return joinItems(o, lengthOf(o), ',', true);
    },
  }.toLocaleString, 0);

  install(AP, 'reverse', {
    reverse() {
      const o = toObject(this);
      const len = lengthOf(o);
      const middle = trunc(len / 2);
      for (let lower = 0; lower !== middle; lower++) {
        const upper = len - lower - 1;
        const lowerExists = lower in o;
        const lowerValue = lowerExists ? o[lower] : undefined;
        const upperExists = upper in o;
        const upperValue = upperExists ? o[upper] : undefined;
        if (lowerExists && upperExists) {
          o[lower] = upperValue;
          o[upper] = lowerValue;
        } else if (upperExists) {
          o[lower] = upperValue;
          delete o[upper];
        } else if (lowerExists) {
          delete o[lower];
          o[upper] = lowerValue;
        }
      }
      return o;
    },
  }.reverse, 0);

  install(AP, 'copyWithin', {
    copyWithin(target, start, end) {
      const o = toObject(this);
      const len = lengthOf(o);
      let to = relIndex(target, len);
      let from = relIndex(start, len);
      const final = end === undefined ? len : relIndex(end, len);
      let count = final - from < len - to ? final - from : len - to;
      let dir = 1;
      if (from < to && to < from + count) {
        dir = -1;
        from = from + count - 1;
        to = to + count - 1;
      }
      for (; count > 0; count--) {
        if (from in o) {
          o[to] = o[from];
        } else {
          delete o[to];
        }
        from += dir;
        to += dir;
      }
      return o;
    },
  }.copyWithin, 2);

  install(AP, 'slice', {
    slice(start, end) {
      const o = toObject(this);
      const len = lengthOf(o);
      let k = relIndex(start, len);
      const final = end === undefined ? len : relIndex(end, len);
      const count = final - k > 0 ? final - k : 0;
      const a = arraySpeciesCreate(o, count);
      let n = 0;
      for (; k < final; k++, n++) {
        if (k in o) defineProperty(a, n, dataDesc(o[k]));
      }
      a.length = n;
      return a;
    },
  }.slice, 2);

  install(AP, 'splice', {
    splice(start, deleteCount, ...items) {
      const o = toObject(this);
      const len = lengthOf(o);
      const actualStart = relIndex(start, len);
      const itemCount = items.length;
      let del;
      if (arguments.length === 0) {
        del = 0;
      } else if (arguments.length === 1) {
        del = len - actualStart;
      } else {
        const dc = toIntegerOrInfinity(deleteCount);
        del = dc < 0 ? 0 : dc < len - actualStart ? dc : len - actualStart;
      }
      // 先减后比较：len + itemCount 可能超出能精确表示的范围。
      if (len - del > MAX_SAFE - itemCount) throw new TypeErr('array too long');
      const a = arraySpeciesCreate(o, del);
      for (let k = 0; k < del; k++) {
        const from = actualStart + k;
        if (from in o) defineProperty(a, k, dataDesc(o[from]));
      }
      a.length = del;
      if (itemCount < del) {
        for (let k = actualStart; k < len - del; k++) {
          const from = k + del;
          const to = k + itemCount;
          if (from in o) {
            o[to] = o[from];
          } else {
            delete o[to];
          }
        }
        for (let k = len; k > len - del + itemCount; k--) delete o[k - 1];
      } else if (itemCount > del) {
        for (let k = len - del; k > actualStart; k--) {
          const from = k + del - 1;
          const to = k + itemCount - 1;
          if (from in o) {
            o[to] = o[from];
          } else {
            delete o[to];
          }
        }
      }
      for (let i = 0; i < itemCount; i++) o[actualStart + i] = items[i];
      o.length = len - del + itemCount;
      return a;
    },
  }.splice, 2);

  install(AP, 'shift', {
    shift() {
      const o = toObject(this);
      const len = lengthOf(o);
      if (len === 0) {
        o.length = 0;
        return undefined;
      }
      const first = o[0];
      for (let k = 1; k < len; k++) {
        if (k in o) {
          o[k - 1] = o[k];
        } else {
          delete o[k - 1];
        }
      }
      delete o[len - 1];
      o.length = len - 1;
      return first;
    },
  }.shift, 0);

  install(AP, 'unshift', {
    unshift(...items) {
      const o = toObject(this);
      const len = lengthOf(o);
      const argCount = items.length;
      if (argCount > 0) {
        if (len + argCount > MAX_SAFE) throw new TypeErr('array too long');
        for (let k = len; k > 0; k--) {
          const from = k - 1;
          const to = k + argCount - 1;
          if (from in o) {
            o[to] = o[from];
          } else {
            delete o[to];
          }
        }
        for (let j = 0; j < argCount; j++) o[j] = items[j];
      }
      o.length = len + argCount;
      return len + argCount;
    },
  }.unshift, 1);

  install(AP, 'sort', {
    sort(comparefn) {
      if (comparefn !== undefined && typeof comparefn !== 'function') {
        throw new TypeErr('comparefn must be a function');
      }
      const o = toObject(this);
      const len = lengthOf(o);
      const items = privateArray();
      let n = 0;
      for (let k = 0; k < len; k++) {
        if (k in o) items[n++] = o[k];
      }
      apply(nSort, items, comparefn === undefined ? [] : [comparefn]);
      for (let j = 0; j < n; j++) o[j] = items[j];
      for (let j = n; j < len; j++) delete o[j];
      return o;
    },
  }.sort, 1);

  const spreadable = (o) => {
    if (!isObject(o)) return false;
    const s = o[symSpreadable];
    if (s !== undefined) return !!s;
    return isArray(o);
  };
  install(AP, 'concat', {
    concat(...items) {
      const o = toObject(this);
      const a = arraySpeciesCreate(o, 0);
      let n = 0;
      for (let i = -1; i < items.length; i++) {
        const e = i < 0 ? o : items[i];
        if (spreadable(e)) {
          const len = lengthOf(e);
          if (n + len > MAX_SAFE) throw new TypeErr('array too long');
          for (let k = 0; k < len; k++, n++) {
            if (k in e) defineProperty(a, n, dataDesc(e[k]));
          }
        } else {
          if (n >= MAX_SAFE) throw new TypeErr('array too long');
          defineProperty(a, n++, dataDesc(e));
        }
      }
      a.length = n;
      return a;
    },
  }.concat, 1);

  const arraySpeciesCreate = (o, len) => {
    if (!isArray(o)) return new Arr(len);
    let c = o.constructor;
    if (isObject(c)) {
      c = c[symSpecies];
      if (c === null) c = undefined;
    }
    if (c === undefined) return new Arr(len);
    if (!isConstructor(c)) throw new TypeErr('not a constructor');
    return construct(c, [len]);
  };
  // FlattenIntoArray（ECMA-262 §23.1.3.13.1），逐项执行。
  const flatten = (target, source, sourceLen, start, depth, mapper, thisArg) => {
    let targetIndex = start;
    for (let i = 0; i < sourceLen; i++) {
      if (!(i in source)) continue;
      let element = source[i];
      if (mapper !== undefined) element = apply(mapper, thisArg, [element, i, source]);
      if (depth > 0 && isArray(element)) {
        targetIndex = flatten(target, element, toLength(element.length), targetIndex,
          depth === Infinity ? Infinity : depth - 1);
      } else {
        if (targetIndex >= MAX_SAFE) throw new TypeErr('array too long');
        defineProperty(target, targetIndex, dataDesc(element));
        targetIndex++;
      }
    }
    return targetIndex;
  };
  install(AP, 'flat', {
    flat(depth) {
      const o = toObject(this);
      const len = toLength(o.length);
      let d = 1;
      if (depth !== undefined) {
        d = toIntegerOrInfinity(depth);
        if (d < 0) d = 0;
      }
      const a = arraySpeciesCreate(o, 0);
      flatten(a, o, len, 0, d);
      return a;
    },
  }.flat, 0);
  install(AP, 'flatMap', {
    flatMap(mapper, thisArg) {
      const o = toObject(this);
      const len = toLength(o.length);
      if (typeof mapper !== 'function') throw new TypeErr('not a function');
      const a = arraySpeciesCreate(o, 0);
      flatten(a, o, len, 0, 1, mapper, thisArg);
      return a;
    },
  }.flatMap, 1);

  // --- 字符串查找 ----------------------------------------------------------------

  // s 从 j 开始是否等于 t（t.length > 0）。按块比较，每次原生调用的工作量有上限。
  const matchesAt = (s, t, j) => {
    const m = t.length;
    for (let k = 0; k < m; k += CHUNK) {
      if (!apply(nStartsWith, s, [slice(t, k, k + CHUNK), j + k])) return false;
    }
    return true;
  };
  // StringIndexOf(s, t, from)，0 <= from <= s.length。
  const find = (s, t, from) => {
    const n = s.length;
    const m = t.length;
    if (m === 0) return from;
    if ((n - from) * m <= MAX_WORK) return apply(nIndexOf, s, [t, from]);
    const c = t[0];
    const last = n - m;
    let i = from;
    while (i <= last) {
      const end = i + CHUNK <= last + 1 ? i + CHUNK : last + 1;
      const k = apply(nIndexOf, slice(s, i, end), [c]);
      if (k < 0) {
        i = end;
        continue;
      }
      const j = i + k;
      if (matchesAt(s, t, j)) return j;
      i = j + 1;
    }
    return -1;
  };
  // 从 start 往前找最后一次出现的位置（start 已按 s.length - t.length 截断）。
  const findLast = (s, t, start) => {
    const m = t.length;
    if (m === 0) return start;
    if ((start + 1) * m <= MAX_WORK) return apply(nLastIndexOf, s, [t, start]);
    const c = t[0];
    let i = start;
    while (i >= 0) {
      const lo = i - CHUNK + 1 > 0 ? i - CHUNK + 1 : 0;
      const k = apply(nLastIndexOf, slice(s, lo, i + 1), [c]);
      if (k < 0) {
        i = lo - 1;
        continue;
      }
      const j = lo + k;
      if (matchesAt(s, t, j)) return j;
      i = j - 1;
    }
    return -1;
  };
  // 原生实现的工作量是否在上限内（只对两个字符串原值判断，不会执行脚本代码）。
  const cheap = (s, t) =>
    typeof s === 'string' && typeof t === 'string' && s.length * t.length <= MAX_WORK;

  // GetSubstitution，无捕获组、无命名捕获组（字符串模式）。
  const substitute = (matched, str, position, template) => {
    let result = '';
    let i = 0;
    const n = template.length;
    for (;;) {
      const d = apply(nIndexOf, template, ['$', i]);
      if (d < 0 || d + 1 >= n) return result + slice(template, i, n);
      result += slice(template, i, d);
      const ch = template[d + 1];
      if (ch === '$') {
        result += '$';
        i = d + 2;
      } else if (ch === '&') {
        result += matched;
        i = d + 2;
      } else if (ch === '`') {
        result += slice(str, 0, position);
        i = d + 2;
      } else if (ch === "'") {
        const tail = position + matched.length;
        result += slice(str, tail < str.length ? tail : str.length, str.length);
        i = d + 2;
      } else {
        result += '$';
        i = d + 1;
      }
    }
  };

  const indexOf = SP.indexOf;
  install(SP, 'indexOf', {
    indexOf(searchString, position) {
      if (cheap(this, searchString)) return apply(indexOf, this, arguments);
      const s = toStr(requireCoercible(this));
      const t = toStr(searchString);
      const pos = toIntegerOrInfinity(position);
      const start = pos < 0 ? 0 : pos > s.length ? s.length : pos;
      return find(s, t, start);
    },
  }.indexOf, indexOf.length);

  const includes = SP.includes;
  install(SP, 'includes', {
    includes(searchString, position) {
      if (cheap(this, searchString)) return apply(includes, this, arguments);
      const s = toStr(requireCoercible(this));
      if (isRegExp(searchString)) {
        throw new TypeErr('First argument must not be a regular expression');
      }
      const t = toStr(searchString);
      const pos = toIntegerOrInfinity(position);
      const start = pos < 0 ? 0 : pos > s.length ? s.length : pos;
      return find(s, t, start) !== -1;
    },
  }.includes, includes.length);

  const lastIndexOf = SP.lastIndexOf;
  install(SP, 'lastIndexOf', {
    lastIndexOf(searchString, position) {
      if (cheap(this, searchString)) return apply(lastIndexOf, this, arguments);
      const s = toStr(requireCoercible(this));
      const t = toStr(searchString);
      const numPos = +position;
      const pos = numPos !== numPos ? Infinity : trunc(numPos);
      const len = s.length;
      let start = pos < 0 ? 0 : pos > len ? len : pos;
      if (start > len - t.length) start = len - t.length;
      if (start < 0) return -1;
      return findLast(s, t, start);
    },
  }.lastIndexOf, lastIndexOf.length);

  const split = SP.split;
  install(SP, 'split', {
    split(separator, limitArg) {
      if (cheap(this, separator)) return apply(split, this, arguments);
      requireCoercible(this);
      if (separator != null) {
        const splitter = getMethod(separator, symSplit);
        if (splitter !== undefined) return apply(splitter, separator, [this, limitArg]);
      }
      const s = toStr(this);
      const lim = limitArg === undefined ? 4294967295 : toUint32(limitArg);
      const r = toStr(separator);
      const out = [];
      if (lim === 0) return out;
      if (separator === undefined) {
        defineProperty(out, 0, dataDesc(s));
        return out;
      }
      const sepLen = r.length;
      if (sepLen === 0) {
        const n = s.length < lim ? s.length : lim;
        for (let i = 0; i < n; i++) defineProperty(out, i, dataDesc(s[i]));
        return out;
      }
      if (s.length === 0) {
        defineProperty(out, 0, dataDesc(s));
        return out;
      }
      let count = 0;
      let i = 0;
      let j = find(s, r, 0);
      while (j !== -1) {
        defineProperty(out, count++, dataDesc(slice(s, i, j)));
        if (count === lim) return out;
        i = j + sepLen;
        j = i <= s.length ? find(s, r, i) : -1;
      }
      defineProperty(out, count, dataDesc(slice(s, i, s.length)));
      return out;
    },
  }.split, split.length);

  const replace = SP.replace;
  install(SP, 'replace', {
    replace(searchValue, replaceValue) {
      if (cheap(this, searchValue)) return apply(replace, this, arguments);
      requireCoercible(this);
      if (searchValue != null) {
        const replacer = getMethod(searchValue, symReplace);
        if (replacer !== undefined) {
          return apply(replacer, searchValue, [this, replaceValue]);
        }
      }
      const s = toStr(this);
      const t = toStr(searchValue);
      const functional = typeof replaceValue === 'function';
      const template = functional ? undefined : toStr(replaceValue);
      const p = find(s, t, 0);
      if (p === -1) return s;
      const replacement = functional
        ? toStr(apply(replaceValue, undefined, [t, p, s]))
        : substitute(t, s, p, template);
      return slice(s, 0, p) + replacement + slice(s, p + t.length, s.length);
    },
  }.replace, replace.length);

  const replaceAll = SP.replaceAll;
  install(SP, 'replaceAll', {
    replaceAll(searchValue, replaceValue) {
      if (cheap(this, searchValue)) return apply(replaceAll, this, arguments);
      requireCoercible(this);
      if (searchValue != null) {
        if (isRegExp(searchValue)) {
          const flags = searchValue.flags;
          requireCoercible(flags);
          if (apply(nIndexOf, toStr(flags), ['g']) < 0) {
            throw new TypeErr('replaceAll must be called with a global RegExp');
          }
        }
        const replacer = getMethod(searchValue, symReplace);
        if (replacer !== undefined) {
          return apply(replacer, searchValue, [this, replaceValue]);
        }
      }
      const s = toStr(this);
      const t = toStr(searchValue);
      const functional = typeof replaceValue === 'function';
      const template = functional ? undefined : toStr(replaceValue);
      const m = t.length;
      const advance = m > 0 ? m : 1;
      let result = '';
      let end = 0;
      let p = find(s, t, 0);
      while (p !== -1) {
        const replacement = functional
          ? toStr(apply(replaceValue, undefined, [t, p, s]))
          : substitute(t, s, p, template);
        result += slice(s, end, p) + replacement;
        end = p + m;
        const next = p + advance;
        p = next <= s.length ? find(s, t, next) : -1;
      }
      if (end < s.length) result += slice(s, end, s.length);
      return result;
    },
  }.replaceAll, replaceAll.length);
})();
''';
