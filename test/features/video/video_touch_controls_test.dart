import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/features/video/player/video_playback.dart';
import 'package:tsumugi/features/video/player/video_touch_controls.dart';

class FakePlayback extends ValueNotifier<VideoPlaybackState>
    implements VideoPlayback {
  FakePlayback(super.value);

  final calls = <String>[];
  final seeks = <Duration>[];

  @override
  Future<void> play() async {
    calls.add('play');
    value = value.copyWith(playing: true);
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    value = value.copyWith(playing: false);
  }

  @override
  Future<void> seek(Duration position) async {
    calls.add('seek');
    seeks.add(position);
    value = value.copyWith(position: position);
  }

  @override
  Future<void> setRate(double rate) async {
    calls.add('rate $rate');
    value = value.copyWith(rate: rate);
  }
}

void main() {
  const area = ValueKey('video-gesture-area');

  Future<(FakePlayback, List<String>)> pump(
    WidgetTester tester, {
    bool playing = true,
    Duration position = const Duration(minutes: 1),
    Duration duration = const Duration(minutes: 10),
    bool loading = false,
    bool fullscreen = false,
  }) async {
    final playback = FakePlayback(
      VideoPlaybackState(
        position: position,
        duration: duration,
        playing: playing,
      ),
    );
    final events = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 800,
            height: 450,
            child: VideoTouchControls(
              playback: playback,
              loading: loading,
              fullscreen: fullscreen,
              title: '第 1 集',
              onToggleFullscreen: () => events.add('fullscreen'),
              onBack: () => events.add('back'),
            ),
          ),
        ),
      ),
    );
    return (playback, events);
  }

  double barOpacity(WidgetTester tester, String tooltip) => tester
      .widget<AnimatedOpacity>(
        find.ancestor(
          of: find.byTooltip(tooltip),
          matching: find.byType(AnimatedOpacity),
        ),
      )
      .opacity;

  /// 单击：等过双击判定时间。
  Future<void> tap(WidgetTester tester) async {
    await tester.tap(find.byKey(area));
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
  }

  Future<void> doubleTap(WidgetTester tester) async {
    await tester.tap(find.byKey(area));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byKey(area));
    await tester.pumpAndSettle();
  }

  test('formatVideoTime', () {
    expect(formatVideoTime(Duration.zero), '0:00');
    expect(formatVideoTime(const Duration(seconds: 65)), '1:05');
    expect(formatVideoTime(const Duration(hours: 1, seconds: 5)), '1:00:05');
    expect(formatVideoTime(const Duration(seconds: -3)), '0:00');
  });

  testWidgets('单击显示 / 隐藏控件；播放中 3 s 后自动隐藏', (tester) async {
    await pump(tester);
    expect(barOpacity(tester, '全屏'), 1);

    await tap(tester);
    expect(barOpacity(tester, '全屏'), 0);

    await tap(tester);
    expect(barOpacity(tester, '全屏'), 1);

    await tester.pump(const Duration(seconds: 3));
    expect(barOpacity(tester, '全屏'), 0);
  });

  testWidgets('暂停时控件不自动隐藏', (tester) async {
    await pump(tester, playing: false);
    await tester.pump(const Duration(seconds: 5));
    expect(barOpacity(tester, '全屏'), 1);
  });

  testWidgets('双击播放 / 暂停，不切换控件显示', (tester) async {
    final (playback, _) = await pump(tester);
    await doubleTap(tester);
    expect(playback.calls, ['pause']);
    expect(barOpacity(tester, '全屏'), 1);

    await doubleTap(tester);
    expect(playback.calls, ['pause', 'play']);
  });

  testWidgets('横向拖动显示目标时间，松手才定位', (tester) async {
    final (playback, _) = await pump(tester);
    final g = await tester.startGesture(tester.getCenter(find.byKey(area)));
    await g.moveBy(const Offset(30, 0)); // 越过拖动判定
    await tester.pump();
    await g.moveBy(const Offset(400, 0)); // 半个宽度 = 45 s
    await tester.pump();

    final indicator = find.byKey(const ValueKey('video-seek-indicator'));
    expect(indicator, findsOneWidget);
    final text = tester
        .widget<Text>(
          find.descendant(of: indicator, matching: find.byType(Text)),
        )
        .data!;
    expect(text, endsWith(' / 10:00'));
    expect(playback.seeks, isEmpty);

    await g.up();
    await tester.pump();
    expect(indicator, findsNothing);
    expect(playback.seeks, hasLength(1));
    final target = playback.seeks.single;
    // 1:00 + 约 45 s（越过判定的那段可能不计入）。
    expect(target, greaterThan(const Duration(seconds: 100)));
    expect(target, lessThanOrEqualTo(const Duration(seconds: 108)));
    expect(text, startsWith(formatVideoTime(target)));
    await tester.pumpAndSettle();
  });

  testWidgets('横向拖动不超出 [0, 时长]', (tester) async {
    final (playback, _) = await pump(
      tester,
      position: const Duration(seconds: 50),
      duration: const Duration(minutes: 1),
    );
    await tester.drag(find.byKey(area), const Offset(2000, 0));
    await tester.pump();
    expect(playback.seeks.single, const Duration(minutes: 1));

    await tester.drag(find.byKey(area), const Offset(-2000, 0));
    await tester.pump();
    expect(playback.seeks.last, Duration.zero);
    await tester.pumpAndSettle();
  });

  testWidgets('没有时长（直播）时横向拖动不定位', (tester) async {
    final (playback, _) = await pump(tester, duration: Duration.zero);
    await tester.drag(find.byKey(area), const Offset(300, 0));
    await tester.pumpAndSettle();
    expect(playback.seeks, isEmpty);
    expect(find.byKey(const ValueKey('video-seek-indicator')), findsNothing);
  });

  testWidgets('长按临时 2 倍速，松手恢复', (tester) async {
    final (playback, _) = await pump(tester);
    final g = await tester.startGesture(tester.getCenter(find.byKey(area)));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    expect(playback.value.rate, 2);
    expect(find.text('2x 倍速中'), findsOneWidget);

    await g.up();
    await tester.pump();
    expect(playback.value.rate, 1);
    expect(find.text('2x 倍速中'), findsNothing);
    expect(playback.calls, ['rate 2.0', 'rate 1.0']);
  });

  testWidgets('暂停时长按不改倍速', (tester) async {
    final (playback, _) = await pump(tester, playing: false);
    await tester.longPress(find.byKey(area));
    await tester.pump();
    expect(playback.calls, isEmpty);
  });

  testWidgets('底栏：播放 / 暂停、全屏按钮', (tester) async {
    final (playback, events) = await pump(tester);
    expect(find.text('1:00'), findsOneWidget);
    expect(find.text('10:00'), findsOneWidget);

    await tester.tap(find.byTooltip('暂停'));
    await tester.pump();
    expect(playback.calls, ['pause']);
    expect(find.byTooltip('播放'), findsOneWidget);

    await tester.tap(find.byTooltip('全屏'));
    await tester.pump();
    expect(events, ['fullscreen']);
    // 非全屏时没有顶栏。
    expect(find.text('第 1 集'), findsNothing);
  });

  testWidgets('全屏：顶栏返回、退出全屏按钮', (tester) async {
    final (_, events) = await pump(tester, fullscreen: true);
    expect(find.text('第 1 集'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.tap(find.byIcon(Icons.fullscreen_exit));
    await tester.pump();
    expect(events, ['back', 'fullscreen']);
  });

  testWidgets('加载中不响应手势、不显示底栏；全屏时仍可返回', (tester) async {
    final (playback, events) = await pump(
      tester,
      loading: true,
      fullscreen: true,
    );
    expect(find.byTooltip('全屏'), findsNothing);
    expect(find.byTooltip('退出全屏'), findsOneWidget); // 顶栏返回

    await doubleTap(tester);
    await tester.drag(find.byKey(area), const Offset(300, 0));
    await tester.longPress(find.byKey(area));
    await tester.pump();
    expect(playback.calls, isEmpty);

    await tester.tap(find.byIcon(Icons.arrow_back));
    expect(events, ['back']);
  });
}
