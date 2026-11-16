import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/shared/video/player_options.dart';

void main() {
  group('waitForVideoOutput', () {
    test('输出已就绪时立即返回', () async {
      await waitForVideoOutput(ValueNotifier<int?>(1));
    });

    test('等到纹理编号到达（Android 上与 Surface 一同到达）才返回', () {
      fakeAsync((async) {
        final id = ValueNotifier<int?>(null);
        var done = false;
        waitForVideoOutput(id).then((_) => done = true);
        async.elapse(const Duration(seconds: 1));
        expect(done, isFalse);
        id.value = 42;
        async.flushMicrotasks();
        expect(done, isTrue);
      });
    });

    test('超时（如只有音轨）后照常返回，并移除监听', () {
      fakeAsync((async) {
        final id = _CountingNotifier();
        var done = false;
        waitForVideoOutput(
          id,
          timeout: const Duration(seconds: 2),
        ).then((_) => done = true);
        expect(id.listeners, 1);
        async.elapse(const Duration(seconds: 2));
        expect(done, isTrue);
        expect(id.listeners, 0);
      });
    });
  });

  group('hasStartedAt', () {
    test('从头播放：位置越过 0 才算开始', () {
      expect(hasStartedAt(Duration.zero, Duration.zero), isFalse);
      expect(
        hasStartedAt(const Duration(milliseconds: 40), Duration.zero),
        isTrue,
      );
    });

    test('续播：打开时的 0 不算，到达起始位置附近才算', () {
      const start = Duration(seconds: 30);
      expect(hasStartedAt(const Duration(milliseconds: 40), start), isFalse);
      expect(hasStartedAt(const Duration(seconds: 29), start), isTrue);
      expect(hasStartedAt(const Duration(seconds: 31), start), isTrue);
    });
  });

  group('waitForPlaybackStart', () {
    late StreamController<Duration> position;
    late StreamController<bool> completed;
    late StreamController<String> failed;

    setUp(() {
      position = StreamController.broadcast();
      completed = StreamController.broadcast();
      failed = StreamController.broadcast();
    });

    Future<void> wait({Duration start = Duration.zero}) => waitForPlaybackStart(
      position: position.stream,
      completed: completed.stream,
      failed: failed.stream,
      start: start,
      timeout: const Duration(seconds: 10),
    );

    test('位置到达起始位置后返回，并取消订阅', () {
      fakeAsync((async) {
        var done = false;
        wait(start: const Duration(seconds: 3)).then((_) => done = true);
        position
          ..add(Duration.zero)
          ..add(const Duration(milliseconds: 500));
        async.flushMicrotasks();
        expect(done, isFalse);
        position.add(const Duration(seconds: 3));
        async.flushMicrotasks();
        expect(done, isTrue);
        expect(position.hasListener, isFalse);
        expect(completed.hasListener, isFalse);
        expect(failed.hasListener, isFalse);
      });
    });

    group('收到新媒体的时长或一次缓冲之前忽略位置（换集时旧媒体残留的位置）', () {
      late StreamController<Duration> duration;
      late StreamController<bool> buffering;
      setUp(() {
        duration = StreamController.broadcast();
        buffering = StreamController.broadcast();
      });

      Future<void> gated() => waitForPlaybackStart(
        position: position.stream,
        completed: completed.stream,
        duration: duration.stream,
        buffering: buffering.stream,
      );

      test('时长到达后', () {
        fakeAsync((async) {
          var done = false;
          gated().then((_) => done = true);
          position.add(const Duration(seconds: 6)); // 旧媒体的结尾
          buffering.add(false); // 旧媒体残留的“缓冲结束”不算
          duration.add(Duration.zero); // 打开新媒体时清零
          async.flushMicrotasks();
          expect(done, isFalse);
          duration.add(const Duration(seconds: 6));
          position.add(const Duration(milliseconds: 100));
          async.flushMicrotasks();
          expect(done, isTrue);
          expect(duration.hasListener, isFalse);
          expect(buffering.hasListener, isFalse);
        });
      });

      test('没有时长的直播流：缓冲开始 → 结束后', () {
        fakeAsync((async) {
          var done = false;
          gated().then((_) => done = true);
          buffering.add(true);
          position.add(const Duration(seconds: 6));
          async.flushMicrotasks();
          expect(done, isFalse);
          buffering.add(false);
          position.add(const Duration(milliseconds: 100));
          async.flushMicrotasks();
          expect(done, isTrue);
        });
      });
    });

    test('播放完成、出错或超时时同样返回', () {
      fakeAsync((async) {
        final done = <String>[];
        wait().then((_) => done.add('completed'));
        completed
          ..add(false)
          ..add(true);
        async.flushMicrotasks();
        expect(done, ['completed']);

        wait().then((_) => done.add('failed'));
        failed.add('boom');
        async.flushMicrotasks();
        expect(done.last, 'failed');

        wait().then((_) => done.add('timeout'));
        async.elapse(const Duration(seconds: 10));
        expect(done.last, 'timeout');
        expect(position.hasListener, isFalse);
      });
    });
  });

  test('播放器选项：不用磁盘缓存、不调用 ytdl', () {
    expect(videoPlayerMpvOptions['cache-on-disk'], 'no');
    expect(videoPlayerMpvOptions['ytdl'], 'no');
  });
}

class _CountingNotifier extends ValueNotifier<int?> {
  _CountingNotifier() : super(null);
  int listeners = 0;

  @override
  void addListener(VoidCallback listener) {
    listeners++;
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    listeners--;
    super.removeListener(listener);
  }
}
