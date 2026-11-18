import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/engine/script/isolate_script_runtime.dart';
import 'package:tsumugi/core/engine/script/quickjs_script_runtime.dart';
import 'package:tsumugi/core/engine/script/script_runtime.dart';

/// #23：交互式宿主调用（`ui.openWebView`）的等待不计入 [ScriptLimits.wallTime]，
/// 改按 [ScriptLimits.interactiveTime] 单独计时（docs/source-spec.md §4.4）。
final _script = File('test/fixtures/scripts/interactive_wait.js')
    .readAsStringSync();

const _limits = ScriptLimits(
  wallTime: Duration(milliseconds: 300),
  interactiveTime: Duration(milliseconds: 900),
  cpuTime: Duration(milliseconds: 200),
);

/// 等待 ms 毫秒；负数表示等待 |ms| 后失败，-1 表示永不结束。
Future<Object?> _wait(List<Object?> a) async {
  final ms = (a.first! as num).toInt();
  if (ms == -1) return Completer<Object?>().future;
  await Future<void>.delayed(Duration(milliseconds: ms.abs()));
  if (ms < 0) {
    throw const ScriptException('cancelled', code: 'E_CHALLENGE');
  }
  return null;
}

final _host = <String, HostFunction>{
  'ui.openWebView': _wait,
  'http.wait': _wait,
};

/// worker 内的测试宿主：在 Dart 代码里忙等，模拟卡住的 worker（必须是顶层函数）。
WorkerHost _spinHost(Object? _) => WorkerHost({
  'test.spin': (a) {
    final until = DateTime.now().add(
      Duration(milliseconds: (a.first! as num).toInt()),
    );
    while (DateTime.now().isBefore(until)) {}
    return null;
  },
});

Matcher _limit(String message) => throwsA(
  isA<ScriptException>()
      .having((e) => e.code, 'code', ScriptException.limit)
      .having((e) => e.message, 'message', contains(message)),
);

var keys = 0;

void main() {
  group('QuickJsScriptRuntime', () {
    late QuickJsScriptRuntime rt;

    setUp(() async {
      rt = QuickJsScriptRuntime(
        host: _host,
        limits: _limits,
        interactive: {'ui.openWebView'},
      );
      await rt.load(_script);
    });

    tearDown(() => rt.dispose());

    test(
      'interactive wait longer than wallTime does not hit E_LIMIT',
      () async {
        expect(await rt.call('login', [600]), 'ok');
      },
    );

    test('interactive wait is capped by interactiveTime', () async {
      final sw = Stopwatch()..start();
      await expectLater(rt.call('login', [5000]), _limit('Interactive'));
      expect(sw.elapsed, lessThan(const Duration(seconds: 3)));
    });

    test('interactive budget is cumulative within one call', () async {
      await expectLater(rt.call('loginTwice', [500]), _limit('Interactive'));
    });

    test('wall clock resumes after the interactive wait', () async {
      // 前后各 200 ms 普通等待，合计 400 ms > 300 ms 总时长；中间的 400 ms 交互等待不计入。
      await expectLater(
        rt.call('slowThenLogin', [200, 400, 200]),
        _limit('Wall time'),
      );
      expect(await rt.call('slowThenLogin', [100, 400, 100]), 'ok');
    });

    test('wall clock resumes after a failed interactive call', () async {
      expect(await rt.call('loginFails', [400, 100]), 'E_CHALLENGE');
      await expectLater(rt.call('loginFails', [100, 400]), _limit('Wall time'));
    });

    test(
      'plain requests during the interactive wait count toward wallTime',
      () async {
        // 普通请求 400 ms 与交互等待重叠，仍计入 300 ms 总时长。
        final sw = Stopwatch()..start();
        await expectLater(
          rt.call('loginAlongside', [600, 400]),
          _limit('Wall time'),
        );
        expect(sw.elapsed, lessThan(const Duration(milliseconds: 600)));
        // 普通请求 100 ms 结束后只剩交互等待：暂停总时长。
        expect(await rt.call('loginAlongside', [600, 100]), 'ok');
        // 永不结束的普通请求：总时长从不暂停。
        await expectLater(
          rt.call('loginAlongside', [600, -1]),
          _limit('Wall time'),
        );
      },
    );

    test('concurrent interactive calls share one budget', () async {
      expect(await rt.call('loginConcurrently', [400, 600]), 'ok');
      await expectLater(
        rt.call('loginConcurrently', [400, 5000]),
        _limit('Interactive'),
      );
    });

    test('CPU budget still applies during the interactive wait', () async {
      await expectLater(rt.call('spinDuringLogin', [5000]), _limit('CPU'));
    });

    test('create() treats ui.openWebView as interactive', () async {
      final created = QuickJsScriptRuntime.create(host: _host, limits: _limits);
      addTearDown(created.dispose);
      await created.load(_script);
      expect(await created.call('login', [600]), 'ok');
    });

    test(
      'non-interactive host functions keep counting toward wallTime',
      () async {
        final plain = QuickJsScriptRuntime(host: _host, limits: _limits);
        addTearDown(plain.dispose);
        await plain.load(_script);
        await expectLater(plain.call('login', [600]), _limit('Wall time'));
      },
    );

    test('interactive paths must be host functions', () {
      expect(
        () => QuickJsScriptRuntime(host: _host, interactive: {'ui.other'}),
        throwsArgumentError,
      );
    });
  });

  group('IsolateScriptRuntime', () {
    IsolateScriptRuntime create() => IsolateScriptRuntime(
      host: _host,
      interactive: {'ui.openWebView'},
      workerHost: _spinHost,
      limits: _limits,
      hangGrace: const Duration(milliseconds: 200),
      // 这些测试只关心看门狗计时，不测暂时停用（见 isolate_script_runtime_test.dart）。
      hangCooldown: Duration.zero,
      maxStuckWorkers: 100,
      maxStuckWorkersGlobal: 100,
      // 无响应记录是进程级的：每个实例用独立的 key，不影响下面用默认 key 的用例。
      hangKey: 'interactive-${++keys}',
    );

    Matcher unresponsive = _limit('unresponsive');

    test(
      'watchdog still fires when the worker hangs during the wait',
      () async {
        final rt = create();
        addTearDown(rt.dispose);
        await rt.load(_script);
        // 看门狗上限：interactiveTime + hangGrace + cpuTime = 1.3 s。
        final sw = Stopwatch()..start();
        await expectLater(
          rt.call('hangDuringLogin', [5000, 4000]),
          unresponsive,
        );
        expect(sw.elapsed, lessThan(const Duration(seconds: 3)));
        expect(await rt.call('login', [10]), 'ok');
        expect(rt.restarts, 1);
      },
    );

    test('watchdog falls back to wallTime after the wait ends', () async {
      final rt = create();
      addTearDown(rt.dispose);
      await rt.load(_script);
      // 交互结束后卡住：上限为 wallTime + hangGrace + cpuTime = 700 ms，远小于 interactiveTime。
      final sw = Stopwatch()..start();
      await expectLater(rt.call('hangAfterLogin', [100, 3000]), unresponsive);
      expect(sw.elapsed, lessThan(const Duration(milliseconds: 1500)));
    });

    test('create() treats ui.openWebView as interactive', () async {
      final rt = IsolateScriptRuntime.create(host: _host, limits: _limits);
      addTearDown(rt.dispose);
      await rt.load(_script);
      expect(await rt.call('login', [600]), 'ok');
    });

    test('watchdog pauses during the interactive wait', () async {
      final rt = create();
      addTearDown(rt.dispose);
      await rt.load(_script);
      // 700 ms > wallTime + hangGrace（500 ms），但 < interactiveTime。
      expect(await rt.call('login', [700]), 'ok');
      expect(rt.restarts, 0);
      // worker 仍可继续使用。
      expect(await rt.call('slowThenLogin', [50, 50, 50]), 'ok');
      expect(rt.restarts, 0);
    });

    test('interactive wait is still capped', () async {
      final rt = create();
      addTearDown(rt.dispose);
      await rt.load(_script);
      await expectLater(rt.call('login', [5000]), _limit('Interactive'));
      // 由 worker 自己按 interactiveTime 中断，不是看门狗放弃 worker。
      expect(await rt.call('login', [10]), 'ok');
      expect(rt.restarts, 0);
    });

    test('interactive paths must be asynchronous host paths', () {
      expect(
        () => IsolateScriptRuntime(host: _host, interactive: {'ui.other'}),
        throwsArgumentError,
      );
      expect(
        () => IsolateScriptRuntime(
          host: _host,
          notifications: {'ui.openWebView'},
          interactive: {'ui.openWebView'},
        ),
        throwsArgumentError,
      );
    });
  });
}
