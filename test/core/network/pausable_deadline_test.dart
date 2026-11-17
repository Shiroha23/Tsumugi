import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/network/pausable_deadline.dart';

void main() {
  PausableDeadline start(FakeAsync async, Duration limit, void Function() f) =>
      PausableDeadline(limit, f, clock: () => async.elapsed);

  test('未暂停时按 limit 到时，只调用一次', () {
    fakeAsync((async) {
      var fired = 0;
      final d = start(async, const Duration(seconds: 60), () => fired++);
      async.elapse(const Duration(seconds: 59));
      expect(fired, 0);
      async.elapse(const Duration(seconds: 1));
      expect(fired, 1);
      expect(d.expired, isTrue);
      d
        ..pause()
        ..resume();
      async.elapse(const Duration(minutes: 5));
      expect(fired, 1);
    });
  });

  test('暂停期间不计时，恢复后从剩余时间继续', () {
    fakeAsync((async) {
      var fired = false;
      final d = start(async, const Duration(seconds: 60), () => fired = true);
      async.elapse(const Duration(seconds: 20));
      d.pause(); // 例如排队等限速令牌
      async.elapse(const Duration(minutes: 10));
      expect(fired, isFalse);
      d.resume();
      async.elapse(const Duration(seconds: 39));
      expect(fired, isFalse);
      async.elapse(const Duration(seconds: 1));
      expect(fired, isTrue);
    });
  });

  test('嵌套暂停：全部恢复后才继续；多余的 resume 无效', () {
    fakeAsync((async) {
      var fired = false;
      final d = start(async, const Duration(seconds: 10), () => fired = true);
      d
        ..pause()
        ..pause();
      async.elapse(const Duration(seconds: 30));
      d.resume();
      async.elapse(const Duration(seconds: 30));
      expect(fired, isFalse);
      d
        ..resume()
        ..resume(); // 多余
      async.elapse(const Duration(seconds: 9));
      expect(fired, isFalse);
      d.pause(); // 多余的 resume 没有让计数变成负数：这次 pause 仍然生效
      async.elapse(const Duration(seconds: 30));
      expect(fired, isFalse);
      d.resume();
      async.elapse(const Duration(seconds: 1));
      expect(fired, isTrue);
    });
  });

  test('cancel 之后不再到时', () {
    fakeAsync((async) {
      var fired = false;
      final d = start(async, const Duration(seconds: 1), () => fired = true);
      d.cancel();
      async.elapse(const Duration(seconds: 5));
      expect(fired, isFalse);
      expect(d.expired, isFalse);
      final p = start(async, const Duration(seconds: 1), () => fired = true)
        ..pause();
      p
        ..cancel()
        ..resume();
      async.elapse(const Duration(seconds: 5));
      expect(fired, isFalse);
    });
  });
}
