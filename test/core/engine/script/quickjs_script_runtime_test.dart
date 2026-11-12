import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/engine/script/quickjs_script_runtime.dart';
import 'package:tsumugi/core/engine/script/script_runtime.dart';

String fixture(String name) =>
    File('test/fixtures/scripts/$name').readAsStringSync();

Matcher throwsScript({String? code, Object? message}) => throwsA(
  isA<ScriptException>()
      .having((e) => e.code, 'code', code)
      .having((e) => e.message, 'message', message ?? anything),
);

void main() {
  late List<String> requests;
  late QuickJsScriptRuntime rt;

  /// 假的 http.get：只认 example.com 的虚构路径。
  Future<Object?> fakeGet(List<Object?> args) async {
    final url = args.first as String;
    requests.add(url);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    if (url.startsWith('/search')) {
      return '{"results":[{"id":"b1","title":" Alpha "},'
          '{"id":"b2","title":"Beta"}],"next":2}';
    }
    if (url == '/book/b1') return '{"title":"Alpha"}';
    if (url == '/book/b1/chapters') return '[1,2,3]';
    if (url == '/never') return Completer<String>().future;
    if (url == '/wait') {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      return '';
    }
    if (url.startsWith('/chapter/')) {
      throw const ScriptException('需要登录', code: 'E_LOGIN_REQUIRED');
    }
    return '';
  }

  QuickJsScriptRuntime create({ScriptLimits limits = const ScriptLimits()}) =>
      QuickJsScriptRuntime(
        host: {
          'http.get': fakeGet,
          'crypto.md5': (args) => 'md5:${args.first}',
        },
        limits: limits,
      );

  setUp(() => requests = []);
  tearDown(() => rt.dispose());

  group('调用导出函数', () {
    setUp(() async {
      rt = create();
      await rt.load(fixture('search_source.js'));
    });

    test('调用导出的 async 函数并取回结构化结果', () async {
      final result = await rt.call('search', ['猫 & 狗', 1]);
      expect(result, {
        'items': [
          {'id': 'b1', 'title': 'Alpha'},
          {'id': 'b2', 'title': 'Beta'},
        ],
        'hasMore': true,
      });
      expect(requests, ['/search?q=%E7%8C%AB%20%26%20%E7%8B%97&page=1']);
    });

    test('多次宿主异步调用往返', () async {
      final result = await rt.call('detail', ['b1']);
      expect(result, {'id': 'b1', 'title': 'Alpha', 'chapters': 3});
      expect(requests, ['/book/b1', '/book/b1/chapters']);
    });

    test('宿主异常以 reject 形式进入脚本，错误码可被脚本读取并上报', () async {
      await expectLater(
        rt.call('content', ['c1']),
        throwsScript(code: 'E_LOGIN_REQUIRED', message: 'wrapped: 需要登录'),
      );
    });

    test('同步宿主函数', () async {
      expect(await rt.call('hash', ['abc']), 'md5:abc');
    });

    test('未导出的函数返回 E_UNSUPPORTED', () async {
      await expectLater(
        rt.call('explore'),
        throwsScript(code: ScriptException.unsupported),
      );
    });

    test('并发调用被串行化且各自得到正确结果', () async {
      final results = await Future.wait([
        rt.call('detail', ['b1']),
        rt.call('search', ['x', 2]),
      ]);
      expect((results[0] as Map)['chapters'], 3);
      expect((results[1] as Map)['hasMore'], true);
    });
  });

  group('沙箱', () {
    setUp(() => rt = create());

    test('只暴露 tsumugi 宿主对象，无 eval / Function / import', () async {
      await rt.load('''
        export async function probe() {
          const r = {};
          r.fetch = typeof fetch;
          r.require = typeof require;
          r.std = typeof std;
          r.os = typeof os;
          r.setTimeout = typeof setTimeout;
          r.tsumugi = Object.keys(tsumugi).sort();
          try { eval('1'); r.eval = 'allowed'; } catch (e) { r.eval = 'blocked'; }
          try { new Function('return 1')(); r.Function = 'allowed'; }
          catch (e) { r.Function = 'blocked'; }
          try { await import('os'); r.import = 'allowed'; }
          catch (e) { r.import = 'blocked'; }
          return r;
        }
      ''');
      expect(await rt.call('probe'), {
        'fetch': 'undefined',
        'require': 'undefined',
        'std': 'undefined',
        'os': 'undefined',
        'setTimeout': 'undefined',
        'tsumugi': ['crypto', 'http'],
        'eval': 'blocked',
        'Function': 'blocked',
        'import': 'blocked',
      });
    });

    test('静态 import 在加载时失败', () async {
      await expectLater(
        rt.load('import * as os from "os"; export const x = 1;'),
        throwsA(isA<ScriptException>()),
      );
    });

    test('宿主对象被冻结，脚本无法替换宿主函数', () async {
      await rt.load('''
        export async function tamper() {
          'use strict';
          try { tsumugi.http.get = () => 'evil'; } catch (e) { return 'frozen'; }
          return 'mutable';
        }
      ''');
      expect(await rt.call('tamper'), 'frozen');
    });

    test('脚本语法错误在加载时报告', () async {
      await expectLater(
        rt.load('export async function (', name: 'broken.js'),
        throwsA(isA<ScriptException>()),
      );
    });
  });

  group('限制', () {
    const cpu = Duration(milliseconds: 300);

    test('死循环在 CPU 预算耗尽时被中断，返回 E_LIMIT', () async {
      rt = create(limits: const ScriptLimits(cpuTime: cpu));
      await rt.load(fixture('limits.js'));
      final sw = Stopwatch()..start();
      await expectLater(
        rt.call('spin'),
        throwsScript(code: ScriptException.limit),
      );
      expect(sw.elapsed, lessThan(const Duration(seconds: 3)));
    });

    test('中断不可被脚本 try/catch 吞掉', () async {
      rt = create(limits: const ScriptLimits(cpuTime: cpu));
      await rt.load(fixture('limits.js'));
      await expectLater(
        rt.call('spinCaught'),
        throwsScript(code: ScriptException.limit),
      );
    });

    test('await 宿主函数之后的死循环同样被中断', () async {
      rt = create(limits: const ScriptLimits(cpuTime: cpu));
      await rt.load(fixture('limits.js'));
      await expectLater(
        rt.call('spinAfterAwait'),
        throwsScript(code: ScriptException.limit),
      );
    });

    test('CPU 预算跨 await 累计；等待宿主的时间不计入', () async {
      rt = create(limits: const ScriptLimits(cpuTime: cpu));
      await rt.load(fixture('limits.js'));
      // 3 × 60ms 忙等 < 300ms：通过（宿主等待不计入）。
      expect(await rt.call('busyBetweenAwaits', [3, 60]), 3);
      // 6 × 80ms 忙等 > 300ms：单段都不超，但累计超限。
      await expectLater(
        rt.call('busyBetweenAwaits', [6, 80]),
        throwsScript(code: ScriptException.limit),
      );
    });

    test('永不完成的宿主 Future 触发总时长上限', () async {
      rt = create(
        limits: const ScriptLimits(wallTime: Duration(milliseconds: 200)),
      );
      await rt.load(fixture('limits.js'));
      await expectLater(
        rt.call('waitForever'),
        throwsScript(code: ScriptException.limit),
      );
    });

    test('超出内存上限返回 E_LIMIT', () async {
      rt = create(limits: const ScriptLimits(memoryBytes: 16 * 1024 * 1024));
      await rt.load(fixture('limits.js'));
      await expectLater(
        rt.call('allocate'),
        throwsScript(code: ScriptException.limit),
      );
    });

    test('无限递归触发栈上限返回 E_LIMIT', () async {
      rt = create();
      await rt.load(fixture('limits.js'));
      await expectLater(
        rt.call('recurse'),
        throwsScript(code: ScriptException.limit),
      );
    });

    for (final export in [
      'throwSpinningGetter',
      'rejectSpinningGetter',
      'returnSpinningToJSON',
    ]) {
      test('读取异常/结果对象时执行的脚本代码同样受 deadline 约束（$export）', () async {
        rt = create(limits: const ScriptLimits(cpuTime: cpu));
        await rt.load(fixture('limits.js'));
        await expectLater(
          rt.call(export),
          throwsScript(code: ScriptException.limit),
        );
        expect(await rt.call('ok'), 'ok');
      });
    }

    test('模块初始化抛出带死循环 getter 的对象时加载被中断', () async {
      rt = create(limits: const ScriptLimits(cpuTime: cpu));
      await expectLater(
        rt.load('throw { get name() { for (;;) {} } };'),
        throwsScript(code: ScriptException.limit),
      );
    });

    test('宿主等待后的同步计算也受剩余总时长约束', () async {
      // CPU 预算充足（5s），但 200ms 等待 + 400ms 计算 > 300ms 总时长。
      rt = create(
        limits: const ScriptLimits(wallTime: Duration(milliseconds: 300)),
      );
      await rt.load(fixture('limits.js'));
      final sw = Stopwatch()..start();
      await expectLater(
        rt.call('waitThenBusy', [400]),
        throwsScript(
          code: ScriptException.limit,
          message: contains('Wall time'),
        ),
      );
      expect(sw.elapsed, lessThan(const Duration(milliseconds: 550)));
      // 总时长内完成则正常返回。
      expect(await rt.call('waitThenBusy', [20]), 'done');
    });

    test('超限之后运行时仍可继续使用', () async {
      rt = create(limits: const ScriptLimits(cpuTime: cpu));
      await rt.load(fixture('limits.js'));
      await expectLater(rt.call('spin'), throwsA(isA<ScriptException>()));
      expect(await rt.call('ok'), 'ok');
    });
  });
}
