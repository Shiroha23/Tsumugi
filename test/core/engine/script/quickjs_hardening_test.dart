import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/engine/script/quickjs_script_runtime.dart';
import 'package:tsumugi/core/engine/script/script_runtime.dart';

/// 回归测试：针对 2026-11 交叉审查中发现的运行时问题。
void main() {
  const cpu = ScriptLimits(cpuTime: Duration(milliseconds: 300));

  late List<String> requests;
  late QuickJsScriptRuntime rt;

  QuickJsScriptRuntime create({
    ScriptLimits limits = const ScriptLimits(),
    Map<String, HostFunction> extra = const {},
  }) => QuickJsScriptRuntime(
    host: {
      'http.get': (args) async {
        requests.add('${args.first}');
        return 'x';
      },
      ...extra,
    },
    limits: limits,
  );

  setUp(() => requests = []);
  tearDown(() => rt.dispose());

  group('调用之间的隔离', () {
    test('被中断调用遗留的微任务不会在下一次调用中执行', () async {
      rt = create(limits: cpu);
      await rt.load('''
        export function first() {
          Promise.resolve().then(() => { for (;;) {} });
          Promise.resolve().then(() => tsumugi.http.get('/stale'));
        }
        export function second() { return 'ok'; }
      ''');
      await expectLater(
        rt.call('first'),
        throwsA(
          isA<ScriptException>().having(
            (e) => e.code,
            'code',
            ScriptException.limit,
          ),
        ),
      );
      expect(await rt.call('second'), 'ok');
      // 再走一轮宿主往返，确认没有迟到的旧任务。
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(requests, isEmpty);
    });

    test('超限后模块重新求值：模块级状态被重置，导出仍可调用', () async {
      rt = create(limits: cpu);
      await rt.load('''
        let n = 0;
        export function inc() { return ++n; }
        export function spin() { for (;;) {} }
      ''');
      expect(await rt.call('inc'), 1);
      expect(await rt.call('inc'), 2);
      await expectLater(rt.call('spin'), throwsA(isA<ScriptException>()));
      expect(await rt.call('inc'), 1);
    });

    test('普通脚本异常不重置模块状态', () async {
      rt = create();
      await rt.load('''
        let n = 0;
        export function inc() { return ++n; }
        export function boom() { throw new Error('boom'); }
      ''');
      expect(await rt.call('inc'), 1);
      await expectLater(rt.call('boom'), throwsA(isA<ScriptException>()));
      expect(await rt.call('inc'), 2);
    });
  });

  group('结果提交时机', () {
    test('入口结果就绪后、同批微任务超限时，调用以 E_LIMIT 失败', () async {
      rt = create(limits: cpu);
      await rt.load('''
        export async function search() {
          await tsumugi.http.get('/tick');
          Promise.resolve().then(() =>
            Promise.resolve().then(() => { for (;;) {} }));
          return 1;
        }
      ''');
      await expectLater(
        rt.call('search'),
        throwsA(
          isA<ScriptException>().having(
            (e) => e.code,
            'code',
            ScriptException.limit,
          ),
        ),
      );
    });

    test('同步返回且无后续微任务时正常提交', () async {
      rt = create();
      await rt.load('export function f() { return { a: [1, 2] }; }');
      expect(await rt.call('f'), {
        'a': [1, 2],
      });
    });
  });

  group('加载', () {
    test('加载失败后实例不可再加载其他脚本，也不可调用', () async {
      rt = create();
      await expectLater(
        rt.load(
          'globalThis.leftover = 123; throw Error("fail");',
          name: 'a.js',
        ),
        throwsA(isA<ScriptException>()),
      );
      await expectLater(
        rt.load('export function search() { return globalThis.leftover; }'),
        throwsA(isA<StateError>()),
      );
      await expectLater(rt.call('search'), throwsA(isA<StateError>()));
    });
  });

  group('错误映射', () {
    test('脚本显式给出的错误码优先，不被消息文本覆盖', () async {
      rt = create();
      await rt.load('''
        export function f() {
          throw { code: 'E_NETWORK', message: 'upstream out of memory' };
        }
      ''');
      await expectLater(
        rt.call('f'),
        throwsA(
          isA<ScriptException>()
              .having((e) => e.code, 'code', 'E_NETWORK')
              .having((e) => e.message, 'message', 'upstream out of memory'),
        ),
      );
    });

    test('普通错误消息含 "out of memory" 不会被当作内存超限', () async {
      rt = create();
      await rt.load(
        'export function f() { throw new Error("cache out of memory"); }',
      );
      await expectLater(
        rt.call('f'),
        throwsA(isA<ScriptException>().having((e) => e.code, 'code', isNull)),
      );
    });

    test('E_HTTP 的 status 在同步抛出与异步 reject 时都保留', () async {
      rt = create();
      await rt.load('''
        export function sync() {
          throw { code: 'E_HTTP', status: 503, message: 'Unavailable' };
        }
        export async function async_() {
          await tsumugi.http.get('/tick');
          throw { code: 'E_HTTP', status: 404, message: 'Not Found' };
        }
      ''');
      await expectLater(
        rt.call('sync'),
        throwsA(
          isA<ScriptException>()
              .having((e) => e.code, 'code', 'E_HTTP')
              .having((e) => e.status, 'status', 503),
        ),
      );
      await expectLater(
        rt.call('async_'),
        throwsA(isA<ScriptException>().having((e) => e.status, 'status', 404)),
      );
    });

    test('宿主抛出的 status 可被脚本读取，并原样上报', () async {
      rt = create(
        extra: {
          'http.request': (args) async =>
              throw const ScriptException('Bad', code: 'E_HTTP', status: 502),
        },
      );
      await rt.load('''
        export async function f() {
          try { await tsumugi.http.request({}); }
          catch (e) { return { code: e.code, status: e.status }; }
        }
        export async function g() { await tsumugi.http.request({}); }
      ''');
      expect(await rt.call('f'), {'code': 'E_HTTP', 'status': 502});
      await expectLater(
        rt.call('g'),
        throwsA(isA<ScriptException>().having((e) => e.status, 'status', 502)),
      );
    });

    test('非整数或越界的 status 被忽略', () async {
      rt = create();
      await rt.load('''
        export function f() { throw { code: 'E_HTTP', status: '503' }; }
        export function g() { throw { code: 'E_HTTP', status: 99999 }; }
      ''');
      for (final f in ['f', 'g']) {
        await expectLater(
          rt.call(f),
          throwsA(
            isA<ScriptException>().having((e) => e.status, 'status', isNull),
          ),
        );
      }
    });
  });
}
