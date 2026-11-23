import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qjs/qjs.dart';
import 'package:tsumugi/core/engine/script/quickjs_script_runtime.dart';
import 'package:tsumugi/core/engine/script/sandbox_hardening.dart';
import 'package:tsumugi/core/engine/script/script_runtime.dart';

/// 内建函数加固（#29，docs/architecture.md §6.1）。
void main() {
  final limitsScript = File('test/fixtures/scripts/builtin_limits.js')
      .readAsStringSync();
  final semantics = File('test/fixtures/scripts/builtin_semantics.js')
      .readAsStringSync();
  final bench = File('test/fixtures/scripts/builtin_bench.js')
      .readAsStringSync();

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

    test('length 只读取一次：之后变大的长度不起作用', () async {
      final rt = QuickJsScriptRuntime(host: const {}, limits: limits);
      addTearDown(rt.dispose);
      await rt.load(limitsScript);
      final quick = [for (final n in await rt.call('quickNames') as List) n];
      expect(quick, isNotEmpty);
      for (final name in quick) {
        final sw = Stopwatch()..start();
        expect(await rt.call('run', [name]), 'finished', reason: '$name');
        expect(
          sw.elapsed,
          lessThan(const Duration(seconds: 1)),
          reason: '$name',
        );
      }
    });
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

    test('一律走可中断的实现', () async {
      expectSame(
        await hardened(
          const SandboxHardening(maxSearchWork: 0, maxNativeArrayLength: -1),
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

  // 常见规模上与原生实现的耗时对比。阈值放宽到足以容忍 CI 的计时抖动，只拦截“明显变慢”。
  test('常见用法的耗时与原生实现相近', () async {
    const long = ScriptLimits(
      cpuTime: Duration(minutes: 2),
      wallTime: Duration(minutes: 3),
    );
    final bare = JSRuntime.create(const JSRuntimeConfig(enableEval: false));
    final List<dynamic> native;
    try {
      native = jsonDecode(
        bare
            .evaluateJavascript('$bench\nJSON.stringify(benchCases());')
            .asDartString,
      ) as List;
    } finally {
      bare.release();
    }
    final rt = QuickJsScriptRuntime(host: const {}, limits: long);
    addTearDown(rt.dispose);
    await rt.load(
      '$bench\nexport function run() { return JSON.stringify(benchCases()); }',
    );
    final hardened = jsonDecode(await rt.call('run') as String) as List;

    // flat / flatMap 一律走逐步执行的实现（architecture §6.1），其余常见规模走原生实现。
    const slowFactor = {'flat': 12, 'flatMap': 12};
    final report = <String>[];
    final tooSlow = <String>[];
    for (var i = 0; i < native.length; i++) {
      final [name as String, base as int] = native[i] as List;
      final ms = (hardened[i] as List)[1] as int;
      report.add('$name: $base ms → $ms ms');
      final factor = slowFactor[name] ?? 2;
      if (ms > base * factor + 30) tooSlow.add(report.last);
    }
    // ignore: avoid_print
    print(report.join('\n'));
    expect(tooSlow, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
