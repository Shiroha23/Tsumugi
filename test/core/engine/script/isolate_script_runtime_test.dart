import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/engine/script/isolate_script_runtime.dart';
import 'package:tsumugi/core/engine/script/script_runtime.dart';

/// worker 内的测试宿主（必须是顶层函数才能发送到 worker）。
WorkerHost _testWorkerHost(Object? config) {
  var calls = 0;
  return WorkerHost({
    'echo.sync': (a) => 'sync:${a.first}',
    'test.calls': (_) => calls,
    // 在 Dart 代码里忙等：QuickJS 的中断 deadline 不起作用，只能靠主 isolate 的看门狗。
    // 有限时长，便于被放弃的 worker 最终回到事件循环并退出。
    'test.spin': (a) {
      final until = DateTime.now().add(Duration(milliseconds: a.first! as int));
      while (DateTime.now().isBefore(until)) {}
      return null;
    },
    // worker 中未捕获的异步错误 → isolate 退出。
    'test.crash': (_) {
      Timer.run(() => throw StateError('boom'));
      return null;
    },
  }, onCallEnd: () => calls++);
}

const _script = '''
let counter = 0;
export async function add(a, b) { return a + b; }
export async function bump() { return ++counter; }
export async function remote(x) { return await tsumugi.echo.async(x); }
export function sync(x) { return tsumugi.echo.sync(x); }
export async function remoteError() {
  try { await tsumugi.echo.fail(); } catch (e) { return [e.code, e.status, e.message]; }
}
export function notify() { return tsumugi.log.info('hi', 1) == null; }
export function calls() { return tsumugi.test.calls(); }
export function loop() { for (;;) {} }
export function spin(ms) { tsumugi.test.spin(ms); }
export async function crash() {
  tsumugi.test.crash();
  return await tsumugi.echo.slow();
}
export async function slowRemote() { return await tsumugi.echo.slow(); }
''';

void main() {
  late List<String> logs;
  late Completer<void> slow;

  IsolateScriptRuntime create({
    ScriptLimits limits = const ScriptLimits(),
    Duration hangGrace = const Duration(seconds: 2),
  }) => IsolateScriptRuntime(
    host: {
      'echo.async': (a) async => 'async:${a.first}',
      'echo.fail': (_) async =>
          throw const ScriptException('nope', code: 'E_HTTP', status: 503),
      'echo.slow': (_) async {
        await slow.future;
        return 'late';
      },
      'log.info': (a) {
        logs.add(a.join(','));
        return 'ignored';
      },
    },
    notifications: {'log.info'},
    workerHost: _testWorkerHost,
    limits: limits,
    hangGrace: hangGrace,
    log: logs.add,
  );

  setUp(() {
    logs = [];
    slow = Completer();
  });

  test('calls exports in the worker and round-trips host functions', () async {
    final rt = create();
    addTearDown(rt.dispose);
    await rt.load(_script);
    expect(await rt.call('add', [2, 3]), 5);
    expect(await rt.call('remote', ['x']), 'async:x');
    expect(await rt.call('sync', ['y']), 'sync:y');
    expect(await rt.call('remoteError'), ['E_HTTP', 503, 'nope']);
    expect(await rt.call('notify'), isTrue);
    await pumpEventQueue();
    expect(logs, contains('hi,1'));
    // onCallEnd 在每次加载 / 调用后执行：load + 5 次调用。
    expect(await rt.call('calls'), 6);
  });

  test('missing export is E_UNSUPPORTED', () async {
    final rt = create();
    addTearDown(rt.dispose);
    await rt.load(_script);
    await expectLater(
      rt.call('nope'),
      throwsA(
        isA<ScriptException>().having((e) => e.code, 'code', 'E_UNSUPPORTED'),
      ),
    );
  });

  test('JS infinite loop is interrupted inside the worker', () async {
    final rt = create(
      limits: const ScriptLimits(cpuTime: Duration(milliseconds: 200)),
    );
    addTearDown(rt.dispose);
    await rt.load(_script);
    expect(await rt.call('bump'), 1);
    await expectLater(
      rt.call('loop'),
      throwsA(isA<ScriptException>().having((e) => e.code, 'code', 'E_LIMIT')),
    );
    // QuickJS 运行时在 worker 内重建：模块状态重置，但 worker 本身未重建。
    expect(await rt.call('bump'), 1);
    expect(rt.restarts, 0);
  });

  test('hung worker is detected, abandoned and rebuilt', () async {
    final rt = create(
      limits: const ScriptLimits(wallTime: Duration(milliseconds: 500)),
      hangGrace: const Duration(milliseconds: 300),
    );
    addTearDown(rt.dispose);
    await rt.load(_script);
    expect(await rt.call('bump'), 1);
    final watch = Stopwatch()..start();
    await expectLater(
      rt.call('spin', [3000]),
      throwsA(
        isA<ScriptException>()
            .having((e) => e.code, 'code', 'E_LIMIT')
            .having((e) => e.message, 'message', contains('unresponsive')),
      ),
    );
    expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    expect(logs.join('\n'), contains('没有回应'));
    // 下一次调用在新 worker 中重新加载脚本。
    expect(await rt.call('bump'), 1);
    expect(rt.restarts, 1);
    expect(await rt.call('add', [1, 1]), 2);
  });

  test('crashed worker is detected and rebuilt', () async {
    final rt = create();
    addTearDown(rt.dispose);
    await rt.load(_script);
    expect(await rt.call('bump'), 1);
    await expectLater(
      rt.call('crash'),
      throwsA(isA<ScriptException>().having((e) => e.code, 'code', 'E_LIMIT')),
    );
    expect(await rt.call('bump'), 1);
    expect(rt.restarts, 1);
  });

  test('late host results are dropped after the call ends', () async {
    final rt = create(
      limits: const ScriptLimits(wallTime: Duration(milliseconds: 300)),
    );
    addTearDown(rt.dispose);
    await rt.load(_script);
    await expectLater(
      rt.call('slowRemote'),
      throwsA(isA<ScriptException>().having((e) => e.code, 'code', 'E_LIMIT')),
    );
    slow.complete();
    await pumpEventQueue();
    expect(await rt.call('add', [1, 2]), 3);
  });

  test('load failure poisons the instance', () async {
    final rt = create();
    addTearDown(rt.dispose);
    await expectLater(
      rt.load('export function ('),
      throwsA(isA<ScriptException>()),
    );
    await expectLater(rt.call('add', [1, 2]), throwsStateError);
    await expectLater(rt.load(_script), throwsStateError);
  });

  test('dispose fails a pending call', () async {
    final rt = create();
    await rt.load(_script);
    final pending = rt.call('slowRemote');
    await pumpEventQueue();
    rt.dispose();
    await expectLater(pending, throwsA(isA<ScriptException>()));
    await expectLater(rt.call('add', [1, 2]), throwsStateError);
  });
}
