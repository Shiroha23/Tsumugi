/// 沙箱的内建函数加固（#29，docs/architecture.md §6.1）。
///
/// QuickJS 只在执行字节码、调用函数等“检查点”上检查中断 deadline，少数原生内建函数的内部循环
/// 不经过检查点，遇到极端输入时 CPU / 总时长限制对它们无效。这里在脚本求值之前，用受信任的 JS
/// 替换这些内建函数：
///
/// - 按 `length` 循环的数组方法：作用于 `length` 超过 [SandboxHardening.maxArrayLength] 的对象时
///   抛出 [sandboxLimitMessage]（宿主映射为 `E_LIMIT`）；`flat` / `flatMap` 改为 JS 实现
///   （逐项执行，可被中断）。
/// - 字符串子串查找（`indexOf` / `lastIndexOf` / `includes` / `split` / `replace` / `replaceAll`
///   的字符串参数路径）：工作量（两串长度之积）不超过 [SandboxHardening.maxSearchWork] 时
///   直接调用原生实现，否则改用按块比较的 JS 实现，结果与原生一致。
///
/// 替换后的函数只引用加固代码自己保存的原生函数，脚本事后篡改原型不影响它们；
/// 不新增任何全局对象或宿主 API。
library;

/// 加固后的内建函数因输入过大而拒绝执行时抛出的 `RangeError` 的 message。
const sandboxLimitMessage = 'Input exceeds the sandbox limit.';

/// 加固参数。默认值见 docs/source-spec.md §4.4。
class SandboxHardening {
  const SandboxHardening({
    this.maxArrayLength = 1 << 22,
    this.maxSearchWork = 1 << 24,
  });

  /// 数组方法接受的最大 `length`。
  ///
  /// 64 MB 堆中的稠密数组远达不到此值（每个元素至少 16 字节），超过它的只可能是稀疏数组
  /// 或带 `length` 的普通对象，原生实现会在其上空转。
  final int maxArrayLength;

  /// 字符串查找直接走原生实现的最大工作量（被查找串剩余长度 × 模式串长度）。
  final int maxSearchWork;

  /// 返回在脚本之前执行的受信任 JS（一段脚本，执行结果为 `undefined`）。
  String get script => _script
      .replaceAll('__MAX_ARRAY_LENGTH__', '$maxArrayLength')
      .replaceAll('__MAX_SEARCH_WORK__', '$maxSearchWork')
      .replaceAll('__LIMIT_MESSAGE__', sandboxLimitMessage);
}

const _script = r'''
(() => {
  'use strict';
  const MAX_LEN = __MAX_ARRAY_LENGTH__;
  const MAX_WORK = __MAX_SEARCH_WORK__;
  const CHUNK = 4096;
  const LIMIT_MESSAGE = '__LIMIT_MESSAGE__';

  const Obj = Object;
  const Arr = Array;
  const TypeErr = TypeError;
  const RangeErr = RangeError;
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

  const limit = () => new RangeErr(LIMIT_MESSAGE);
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

  const checkLength = (o) => {
    if (toLength(o.length) > MAX_LEN) throw limit();
  };
  for (const name of [
    'join', 'toLocaleString', 'reverse', 'copyWithin', 'slice', 'splice',
    'shift', 'unshift', 'sort',
  ]) {
    const orig = AP[name];
    install(AP, name, {
      [name]() {
        checkLength(toObject(this));
        return apply(orig, this, arguments);
      },
    }[name], orig.length);
  }

  const spreadable = (o) => {
    if (!isObject(o)) return false;
    const s = o[symSpreadable];
    if (s !== undefined) return !!s;
    return isArray(o);
  };
  const concat = AP.concat;
  install(AP, 'concat', {
    concat() {
      const o = toObject(this);
      let total = spreadable(o) ? toLength(o.length) : 1;
      for (let i = 0; i < arguments.length; i++) {
        const e = arguments[i];
        total += spreadable(e) ? toLength(e.length) : 1;
        if (total > MAX_LEN) break;
      }
      if (total > MAX_LEN) throw limit();
      return apply(concat, this, arguments);
    },
  }.concat, concat.length);

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
        if (targetIndex >= 9007199254740991) throw new TypeErr('array too long');
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
