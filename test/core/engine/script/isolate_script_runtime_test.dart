import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/engine/script/isolate_script_runtime.dart';
import 'package:tsumugi/core/engine/script/script_runtime.dart';

/// worker 内的测试宿主（必须是顶层函数才能发送到 worker）。
WorkerHost _testWorkerHost(Object? config) {
  var calls = 0;
  return WorkerHost({
    'echo.sync': (a) => 'sync:${a.first}',
    'test.calls': (_) => calls,
    // config 为文件路径：文件存在时脚本在模块加载阶段卡住（见 fixture）。
    'test.flag': (_) => config is String && File(config).existsSync(),
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

final _script = File('test/fixtures/scripts/isolate_runtime.js')
    .readAsStringSync();

var keys = 0;

void main() {
  late List<String> logs;
  late Completer<void> slow;

  IsolateScriptRuntime create({
    ScriptLimits limits = const ScriptLimits(),
    Duration hangGrace = const Duration(seconds: 2),
    Duration hangCooldown = Duration.zero,
    int maxStuckWorkers = 100,
    int maxStuckWorkersGlobal = 100,
    String? hangKey,
    Object? workerHostConfig,
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
    workerHostConfig: workerHostConfig,
    // 无响应记录是进程级的：每个实例默认用独立的 key，测试之间互不影响。
    hangKey: hangKey ?? 'test-${++keys}',
    limits: limits,
    hangGrace: hangGrace,
    hangCooldown: hangCooldown,
    maxStuckWorkers: maxStuckWorkers,
    maxStuckWorkersGlobal: maxStuckWorkersGlobal,
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

  test('dispose while the worker is still spawning', () async {
    final rt = create();
    final load = rt.load(_script);
    scheduleMicrotask(rt.dispose);
    await expectLater(load, throwsA(isA<Object>()));
    await expectLater(rt.call('add', [1, 2]), throwsStateError);
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

  // --- #29：worker 长时间无响应后暂时停用 -------------------------------------
  // `test.spin` 在 worker 的 Dart 代码里忙等，模拟“不能被中断的执行”：
  // 看门狗放弃 worker 后，它要到 spin 结束才真正退出。

  Matcher suspended = throwsA(
    isA<ScriptException>().having((e) => e.code, 'code', 'E_SUSPENDED'),
  );

  Future<void> waitUntil(bool Function() condition) async {
    final sw = Stopwatch()..start();
    while (!condition()) {
      if (sw.elapsed > const Duration(seconds: 10)) fail('timed out');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  test('slow-to-interrupt engine work: the call fails within the watchdog '
      'bound and the worker is reclaimed', () async {
    final rt = create(
      limits: const ScriptLimits(
        cpuTime: Duration(milliseconds: 100),
        wallTime: Duration(milliseconds: 300),
      ),
      hangGrace: const Duration(milliseconds: 200),
    );
    addTearDown(rt.dispose);
    await rt.load(_script);
    final watch = Stopwatch()..start();
    await expectLater(
      rt.call('busyBuiltins'),
      throwsA(isA<ScriptException>().having((e) => e.code, 'code', 'E_LIMIT')),
    );
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    // 被放弃的 worker 在引擎终于中断后回到事件循环并退出，不再占用线程。
    await waitUntil(() => rt.stuckWorkers == 0);
    expect(await rt.call('add', [1, 1]), 2);
  });

  test(
    'unresponsive worker suspends the runtime during the cooldown',
    () async {
      final rt = create(
        limits: const ScriptLimits(wallTime: Duration(milliseconds: 300)),
        hangGrace: const Duration(milliseconds: 200),
        hangCooldown: const Duration(milliseconds: 800),
      );
      addTearDown(rt.dispose);
      await rt.load(_script);
      expect(rt.suspended, isFalse);
      await expectLater(
        rt.call('spin', [1500]),
        throwsA(
          isA<ScriptException>().having((e) => e.code, 'code', 'E_LIMIT'),
        ),
      );
      expect(rt.suspended, isTrue);
      expect(rt.stuckWorkers, 1);
      // 冷却期内：立即失败，不新建 worker。
      final sw = Stopwatch()..start();
      await expectLater(rt.call('add', [1, 1]), suspended);
      expect(sw.elapsed, lessThan(const Duration(milliseconds: 200)));
      expect(rt.restarts, 0);
      // 冷却结束后恢复：新 worker 重新加载脚本。
      await waitUntil(() => !rt.suspended);
      expect(await rt.call('add', [1, 1]), 2);
      expect(rt.restarts, 1);
      // 被放弃的 worker 最终退出，不再计入。
      await waitUntil(() => rt.stuckWorkers == 0);
    },
  );

  test(
    'too many stuck workers keep the runtime suspended until one exits',
    () async {
      final rt = create(
        limits: const ScriptLimits(wallTime: Duration(milliseconds: 200)),
        hangGrace: const Duration(milliseconds: 100),
        maxStuckWorkers: 2,
      );
      addTearDown(rt.dispose);
      await rt.load(_script);
      // 之前的测试留下的 worker 先退出，全进程计数才可预期。
      await waitUntil(() => IsolateScriptRuntime.stuckWorkersGlobal == 0);
      await expectLater(
        rt.call('spin', [1500]),
        throwsA(isA<ScriptException>()),
      );
      expect(rt.stuckWorkers, 1);
      expect(rt.suspended, isFalse);
      await expectLater(
        rt.call('spin', [1500]),
        throwsA(isA<ScriptException>()),
      );
      expect(rt.stuckWorkers, 2);
      expect(IsolateScriptRuntime.stuckWorkersGlobal, 2);
      expect(rt.suspended, isTrue);
      await expectLater(rt.call('add', [1, 1]), suspended);
      expect(rt.restarts, 1);
      expect(logs.join('\n'), contains('没有回应'));
      // 卡住的 worker 退出后可以重建。
      await waitUntil(() => !rt.suspended);
      expect(await rt.call('add', [2, 2]), 4);
      await waitUntil(() => rt.stuckWorkers == 0);
      expect(logs.join('\n'), contains('已退出'));
    },
  );

  test('stuck workers are also capped across runtimes', () async {
    await waitUntil(() => IsolateScriptRuntime.stuckWorkersGlobal == 0);
    const base = 0;
    IsolateScriptRuntime make() => create(
      limits: const ScriptLimits(wallTime: Duration(milliseconds: 200)),
      hangGrace: const Duration(milliseconds: 100),
      maxStuckWorkersGlobal: base + 1,
    );
    final a = make();
    final b = make();
    addTearDown(a.dispose);
    addTearDown(b.dispose);
    await a.load(_script);
    await b.load(_script);
    await expectLater(a.call('spin', [1500]), throwsA(isA<ScriptException>()));
    // b 的 worker 还活着：照常工作。
    expect(await b.call('add', [1, 2]), 3);
    await expectLater(b.call('spin', [1500]), throwsA(isA<ScriptException>()));
    // 全进程已有 2 个卡住的 worker：两者都不再新建 worker。
    expect(a.suspended, isTrue);
    expect(b.suspended, isTrue);
    await expectLater(b.call('add', [1, 1]), suspended);
    await waitUntil(() => IsolateScriptRuntime.stuckWorkersGlobal <= base);
    expect(await a.call('add', [1, 1]), 2);
  });

  // --- #65：取消 ---------------------------------------------------------------

  Matcher cancelled = throwsA(
    isA<ScriptException>().having((e) => e.code, 'code', 'E_CANCELLED'),
  );

  test('cancelCurrent aborts a call waiting on the host', () async {
    final rt = create();
    addTearDown(rt.dispose);
    await rt.load(_script);
    expect(await rt.call('bump'), 1);
    final pending = rt.call('slowRemote');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    rt.cancelCurrent();
    await expectLater(pending, cancelled);
    // 迟到的宿主结果被丢弃；JS 运行时已重建（模块状态重置），worker 保留。
    slow.complete();
    await pumpEventQueue();
    expect(await rt.call('bump'), 1);
    expect(rt.restarts, 0);
    // 取消请求只作用于那一次调用。
    expect(await rt.call('add', [1, 2]), 3);
  });

  test('cancelCurrent takes effect after synchronous JS finishes', () async {
    final rt = create();
    addTearDown(rt.dispose);
    await rt.load(_script);
    final pending = rt.call('crashLater');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    rt.cancelCurrent();
    await expectLater(pending, cancelled);
    expect(await rt.call('add', [2, 3]), 5);
  });

  // --- #29：无响应记录是进程级的，反复新建实例同样受限 ------------------------

  test('a load that hangs suspends new instances with the same key', () async {
    await waitUntil(() => IsolateScriptRuntime.stuckWorkersGlobal == 0);
    final dir = Directory.systemTemp.createTempSync('tsumugi-hang');
    addTearDown(() => dir.deleteSync(recursive: true));
    final flag = File('${dir.path}/hang')..writeAsStringSync('');
    IsolateScriptRuntime make() => create(
      limits: const ScriptLimits(wallTime: Duration(milliseconds: 200)),
      hangGrace: const Duration(milliseconds: 100),
      hangCooldown: const Duration(milliseconds: 800),
      maxStuckWorkers: 1,
      hangKey: 'load-hang',
      workerHostConfig: flag.path,
    );
    final first = make();
    addTearDown(first.dispose);
    await expectLater(
      first.load(_script),
      throwsA(isA<ScriptException>().having((e) => e.code, 'code', 'E_LIMIT')),
    );
    expect(IsolateScriptRuntime.stuckWorkersGlobal, 1);
    // 新实例（如加载失败后重试）：不再新建 worker。
    for (var i = 0; i < 3; i++) {
      final again = make();
      addTearDown(again.dispose);
      await expectLater(again.load(_script), suspended);
      expect(again.suspension, ScriptSuspension.source);
    }
    expect(IsolateScriptRuntime.stuckWorkersGlobal, 1);
    // 冷却结束、卡住的 worker 退出后恢复。
    flag.deleteSync();
    final later = make();
    addTearDown(later.dispose);
    await waitUntil(() => IsolateScriptRuntime.stuckWorkersGlobal == 0);
    await Future<void>.delayed(const Duration(milliseconds: 800));
    await later.load(_script);
    expect(await later.call('add', [1, 2]), 3);
  });

  test('process-wide cap also blocks loads, reported as process', () async {
    await waitUntil(() => IsolateScriptRuntime.stuckWorkersGlobal == 0);
    final a = create(
      limits: const ScriptLimits(wallTime: Duration(milliseconds: 200)),
      hangGrace: const Duration(milliseconds: 100),
      maxStuckWorkersGlobal: 1,
    );
    addTearDown(a.dispose);
    await a.load(_script);
    await expectLater(a.call('spin', [1500]), throwsA(isA<ScriptException>()));
    final b = create(maxStuckWorkersGlobal: 1);
    addTearDown(b.dispose);
    await expectLater(
      b.load(_script),
      throwsA(
        isA<ScriptException>()
            .having((e) => e.code, 'code', 'E_SUSPENDED')
            .having(
              (e) => e.message,
              'message',
              IsolateScriptRuntime.processWideSuspensionMessage,
            ),
      ),
    );
    expect(b.suspension, ScriptSuspension.process);
    expect(a.suspension, ScriptSuspension.process);
    await waitUntil(() => IsolateScriptRuntime.stuckWorkersGlobal == 0);
  });

  test(
    'a rebuild that hangs keeps the script loaded for a later retry',
    () async {
      final dir = Directory.systemTemp.createTempSync('tsumugi-hang');
      addTearDown(() => dir.deleteSync(recursive: true));
      final flag = File('${dir.path}/hang');
      final rt = create(
        limits: const ScriptLimits(wallTime: Duration(milliseconds: 200)),
        hangGrace: const Duration(milliseconds: 100),
        workerHostConfig: flag.path,
      );
      addTearDown(rt.dispose);
      await rt.load(_script);
      await expectLater(
        rt.call('spin', [1500]),
        throwsA(isA<ScriptException>()),
      );
      // 重建时重新加载也卡住。
      flag.writeAsStringSync('');
      await expectLater(
        rt.call('add', [1, 1]),
        throwsA(
          isA<ScriptException>().having((e) => e.code, 'code', 'E_LIMIT'),
        ),
      );
      flag.deleteSync();
      expect(await rt.call('add', [1, 1]), 2);
    },
  );
}
