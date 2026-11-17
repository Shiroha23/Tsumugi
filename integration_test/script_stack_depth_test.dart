// #41：在真实构建（尤其是 release）中测量脚本源可用的最大 JS 递归深度。
// 测试构建（`flutter test`）的原生库可能未开优化，每层栈帧偏大，结果不代表发布版。
//
// `flutter drive` 不支持 release 模式，因此 release 下把本文件作为应用入口构建后直接运行：
// 结果以 `TSUMUGI_STACK_DEPTH` 开头的一行打印（Android 在 logcat 的 flutter 标签下），
// 设置 TSUMUGI_RESULT_FILE 时另写入该文件；TSUMUGI_EXIT_WHEN_DONE 让应用测完后退出。
//
// Windows：
//
//   flutter build windows --release -t integration_test/script_stack_depth_test.dart
//     --dart-define=TSUMUGI_RESULT_FILE=stack_depth.txt --dart-define=TSUMUGI_EXIT_WHEN_DONE=true
//   build/windows/x64/runner/Release/tsumugi.exe
//
// Android 设备：
//
//   flutter build apk --release -t integration_test/script_stack_depth_test.dart
//     --dart-define=TSUMUGI_EXIT_WHEN_DONE=true
//   adb install -r build/app/outputs/flutter-apk/app-release.apk
//   adb logcat -c; adb shell monkey -p io.github.tsumugi.tsumugi 1; adb logcat -s flutter
//
// debug / profile 下也可以照常用 `flutter test` / `flutter drive` 运行（只检查栈上限生效，不检查深度）。

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tsumugi/core/engine/script/isolate_script_runtime.dart';
import 'package:tsumugi/core/engine/script/quickjs_script_runtime.dart';
import 'package:tsumugi/core/engine/script/script_runtime.dart';

const _resultFile = String.fromEnvironment('TSUMUGI_RESULT_FILE');
const _exitWhenDone = bool.fromEnvironment('TSUMUGI_EXIT_WHEN_DONE');

/// 发布版的回归下限：source-spec §4.4 对源作者承诺的约 100 层
/// （2026-11 实测 Windows 107 层、Android 487 层）。
const _documentedMinDepth = 100;

const _script = '''
function depth(n) { return n === 0 ? 0 : 1 + depth(n - 1); }
export function probe(n) {
  try { return depth(n); } catch (e) { return -1; }
}
''';

/// 二分查找能完成的最大递归深度（超限的那一层由脚本 catch，返回 -1）。
Future<int> _maxDepth(ScriptRuntime rt) async {
  Future<bool> ok(int n) async => await rt.call('probe', [n]) == n;
  var lo = 0;
  var hi = 1;
  while (await ok(hi)) {
    lo = hi;
    hi *= 2;
    if (hi > 1 << 20) return lo; // 栈上限失效时不要一直探下去。
  }
  while (hi - lo > 1) {
    final mid = (lo + hi) ~/ 2;
    if (await ok(mid)) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  return lo;
}

void _record(String line) {
  // ignore: avoid_print
  print(line);
  if (_resultFile.isNotEmpty) {
    File(_resultFile).writeAsStringSync('$line\n', mode: FileMode.append);
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  var verdict = 'FAIL';

  tearDownAll(() {
    _record('TSUMUGI_STACK_DEPTH_RESULT $verdict');
    if (_exitWhenDone) exit(verdict == 'PASS' ? 0 : 1);
  });

  test('max JS recursion depth with default ScriptLimits', () async {
    // 脚本源的实际执行路径：worker isolate 中的 QuickJS。
    final worker = IsolateScriptRuntime();
    addTearDown(worker.dispose);
    await worker.load(_script);
    final workerDepth = await _maxDepth(worker);

    // 声明式引擎的 js: 片段：调用方（主）isolate 上的 QuickJS。
    final main = QuickJsScriptRuntime(host: const {});
    addTearDown(main.dispose);
    await main.load(_script);
    final mainDepth = await _maxDepth(main);

    final mode = kReleaseMode
        ? 'release'
        : kProfileMode
        ? 'profile'
        : 'debug';
    _record(
      'TSUMUGI_STACK_DEPTH os=${Platform.operatingSystem} mode=$mode '
      'maxStackBytes=${const ScriptLimits().maxStackBytes} '
      'worker=$workerDepth main=$mainDepth',
    );
    binding.reportData = {
      'os': Platform.operatingSystem,
      'mode': mode,
      'worker': workerDepth,
      'main': mainDepth,
    };

    // 栈检查必须真的生效（深度有限），且发布版达到文档写明的深度。
    expect(workerDepth, inExclusiveRange(0, 1 << 20));
    expect(mainDepth, inExclusiveRange(0, 1 << 20));
    if (kReleaseMode) {
      expect(workerDepth, greaterThanOrEqualTo(_documentedMinDepth));
      expect(mainDepth, greaterThanOrEqualTo(_documentedMinDepth));
    }

    // 超限后运行时仍可继续使用。
    expect(await worker.call('probe', [10]), 10);
    expect(await main.call('probe', [10]), 10);
    verdict = 'PASS';
  });
}
