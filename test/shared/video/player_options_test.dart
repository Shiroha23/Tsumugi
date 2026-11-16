import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/shared/video/player_options.dart';

void main() {
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
