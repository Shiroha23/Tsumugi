import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qjs/qjs.dart';
import 'package:tsumugi/core/engine/script/quickjs_script_runtime.dart';
import 'package:tsumugi/core/engine/script/sandbox_hardening.dart';
import 'package:tsumugi/core/engine/script/script_runtime.dart';

/// 内建函数加固（#29，docs/architecture.md §6.1）。
void main() {
  final limitsScript = File(
    'test/fixtures/scripts/builtin_limits.js',
  ).readAsStringSync();
  final semantics = File(
    'test/fixtures/scripts/builtin_semantics.js',
  ).readAsStringSync();

  const cpu = Duration(milliseconds: 200);
  const limits = ScriptLimits(cpuTime: cpu, wallTime: Duration(minutes: 1));

  group('大输入上的内建函数受时间限制', () {
    late List<String> names;

    setUpAll(() async {
      final rt = QuickJsScriptRuntime(host: const {});
      await rt.load(limitsScript);
      names = [for (final n in await rt.call('names') as List) n as String];
      rt.dispose();
    });

    // 每个入口单独建运行时；未加固时这些调用要跑数秒以上才结束。
    test('每个入口都在 CPU 上限附近以 E_LIMIT 结束', () async {
      expect(names, isNotEmpty);
      final slow = <String>[];
      for (final name in names) {
        final rt = QuickJsScriptRuntime(host: const {}, limits: limits);
        await rt.load(limitsScript);
        final sw = Stopwatch()..start();
        Object? outcome;
        try {
          outcome = await rt.call('run', [name]);
        } on ScriptException catch (e) {
          outcome = e.code;
        }
        sw.stop();
        rt.dispose();
        if (outcome != ScriptException.limit ||
            sw.elapsed > cpu + const Duration(seconds: 2)) {
          slow.add('$name: $outcome in ${sw.elapsedMilliseconds} ms');
        }
      }
      expect(slow, isEmpty);
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  group('行为与原生实现一致', () {
    late String expected;

    setUpAll(() {
      final rt = JSRuntime.create(const JSRuntimeConfig(enableEval: false));
      try {
        expected = rt
            .evaluateJavascript('$semantics\nJSON.stringify(semanticCases());')
            .asDartString;
      } finally {
        rt.release();
      }
    });

    Future<String> hardened(SandboxHardening hardening) async {
      final rt = QuickJsScriptRuntime(host: const {}, hardening: hardening);
      try {
        await rt.load(
          '$semantics\nexport function run() { '
          'return JSON.stringify(semanticCases()); }',
        );
        return await rt.call('run') as String;
      } finally {
        rt.dispose();
      }
    }

    void expectSame(String actual) {
      final a = jsonDecode(actual) as List;
      final e = jsonDecode(expected) as List;
      expect(a.length, e.length);
      for (var i = 0; i < e.length; i++) {
        expect(a[i], e[i]);
      }
    }

    test('默认参数（小输入走原生实现）', () async {
      expectSame(await hardened(const SandboxHardening()));
    });

    test('查找一律走可中断的实现', () async {
      expectSame(
        await hardened(
          const SandboxHardening(maxSearchWork: 0, maxArrayLength: 1 << 22),
        ),
      );
    });

    test('脚本篡改原型后，加固后的函数照常工作', () async {
      final rt = QuickJsScriptRuntime(
        host: const {},
        hardening: const SandboxHardening(maxSearchWork: 0),
      );
      addTearDown(rt.dispose);
      await rt.load('''
        export function run() {
          Array.prototype.push = () => { throw new Error('push'); };
          String.prototype.slice = () => { throw new Error('slice'); };
          String.prototype.startsWith = () => { throw new Error('startsWith'); };
          Object.defineProperty(Array.prototype, '0', {
            set() { throw new Error('set'); }, configurable: true,
          });
          Object.defineProperty(Object.prototype, 'get', {
            get() { throw new Error('get'); }, configurable: true,
          });
          Reflect.apply = () => { throw new Error('apply'); };
          Object.defineProperty = () => { throw new Error('defineProperty'); };
          const results = [
            'xxabcxx'.indexOf('abc'),
            'abcabc'.lastIndexOf('bc'),
            'a,b,c'.split(','),
            'abc'.replace('b', '[\$&]'),
            'abab'.replaceAll('a', '-'),
            [1, [2, [3]]].flat(2),
          ];
          // 结果传回宿主时也会用到这两项，先恢复。
          delete Object.prototype.get;
          delete Array.prototype[0];
          return results;
        }
      ''');
      expect(await rt.call('run'), [
        2,
        4,
        ['a', 'b', 'c'],
        'a[b]c',
        '-b-b',
        [1, 2, 3],
      ]);
    });
  });

  group('输入上限', () {
    const small = SandboxHardening(maxArrayLength: 10);

    test('超出上限且未被捕获时以 E_LIMIT 结束，运行时之后可继续使用', () async {
      final rt = QuickJsScriptRuntime(host: const {}, hardening: small);
      addTearDown(rt.dispose);
      await rt.load('''
        export function big() { return Array.prototype.join.call({ length: 11 }); }
        export function edge() { return Array.prototype.join.call({ length: 10 }, '-'); }
      ''');
      await expectLater(
        rt.call('big'),
        throwsA(
          isA<ScriptException>().having(
            (e) => e.code,
            'code',
            ScriptException.limit,
          ),
        ),
      );
      expect(await rt.call('edge'), '---------');
    });

    test('脚本可以捕获该异常', () async {
      final rt = QuickJsScriptRuntime(host: const {}, hardening: small);
      addTearDown(rt.dispose);
      await rt.load('''
        export function run() {
          try { new Array(11).reverse(); return 'no'; }
          catch (e) { return [e instanceof RangeError, e.message]; }
        }
      ''');
      expect(await rt.call('run'), [true, sandboxLimitMessage]);
    });

    test('concat 按展开后的总长度判断', () async {
      final rt = QuickJsScriptRuntime(host: const {}, hardening: small);
      addTearDown(rt.dispose);
      await rt.load('''
        export function ok() { return [1, 2, 3].concat([4, 5, 6], 7, 8, 9, 10).length; }
        export function over() { return [1, 2, 3].concat([4, 5, 6], [7, 8, 9, 10, 11]); }
      ''');
      expect(await rt.call('ok'), 10);
      await expectLater(rt.call('over'), throwsA(isA<ScriptException>()));
    });
  });
}
