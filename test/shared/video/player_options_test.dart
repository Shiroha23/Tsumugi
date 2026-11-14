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

  group('needsRestart', () {
    test('开头附近不需要', () {
      expect(needsRestart(Duration.zero, completed: false), isFalse);
      expect(
        needsRestart(const Duration(milliseconds: 110), completed: false),
        isFalse,
      );
    });

    test('Android 上 Surface 就绪后的 seek 落到结尾 / 中间时需要', () {
      // 真机日志：首个进度 0:00:06.037188 → completed；或 0:00:02.113111。
      expect(
        needsRestart(
          const Duration(seconds: 6, microseconds: 37188),
          completed: false,
        ),
        isTrue,
      );
      expect(
        needsRestart(
          const Duration(seconds: 2, microseconds: 113111),
          completed: false,
        ),
        isTrue,
      );
      expect(needsRestart(Duration.zero, completed: true), isTrue);
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
