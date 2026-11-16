import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/features/video/player/video_fullscreen.dart';
import 'package:tsumugi/features/video/player/video_player_layout.dart';

class FakeSystemUi implements VideoSystemUi {
  final calls = <Object>[];

  @override
  Future<void> setSystemUiMode(SystemUiMode mode) async => calls.add(mode);

  @override
  Future<void> setOrientations(List<DeviceOrientation> orientations) async =>
      calls.add(orientations);
}

/// 播放页的替身：用 [VideoPlayerLayout] 与 [VideoFullscreenController]，播放器是一个计数器（检查状态是否保留）。
class _Page extends StatefulWidget {
  const _Page({required this.controller});

  final VideoFullscreenController controller;

  @override
  State<_Page> createState() => _PageState();
}

class _PageState extends State<_Page> {
  final _playerKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    widget.controller.restore();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => VideoPlayerLayout(
    fullscreen: widget.controller.isFullscreen,
    onExitFullscreen: () => widget.controller.exit(phone: true),
    appBar: AppBar(title: const Text('标题栏')),
    player: KeyedSubtree(key: _playerKey, child: const _Counter()),
    panel: const Text('选集面板'),
  );
}

class _Counter extends StatefulWidget {
  const _Counter();

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int _n = 0;

  @override
  Widget build(BuildContext context) =>
      TextButton(onPressed: () => setState(() => _n++), child: Text('播放器 $_n'));
}

void main() {
  group('VideoFullscreenController', () {
    test('横向视频横屏全屏，竖向视频竖屏全屏，尺寸未知按横屏', () async {
      for (final (aspect, orientations) in [
        (16 / 9, landscapeOrientations),
        (1.0, landscapeOrientations),
        (null, landscapeOrientations),
        (9 / 16, portraitOrientations),
      ]) {
        final ui = FakeSystemUi();
        final c = VideoFullscreenController(systemUi: ui);
        await c.enter(aspectRatio: aspect);
        expect(c.isFullscreen, isTrue);
        expect(c.landscape, orientations == landscapeOrientations);
        expect(ui.calls, [SystemUiMode.immersiveSticky, orientations]);
      }
    });

    test('退出：恢复系统栏；手机锁回竖屏，平板不限制', () async {
      final ui = FakeSystemUi();
      final c = VideoFullscreenController(systemUi: ui);
      await c.enter(aspectRatio: 16 / 9);
      ui.calls.clear();
      await c.exit(phone: true);
      expect(c.isFullscreen, isFalse);
      expect(c.landscape, isNull);
      expect(ui.calls, [SystemUiMode.edgeToEdge, portraitOrientations]);

      await c.enter();
      ui.calls.clear();
      await c.exit(phone: false);
      expect(ui.calls, [SystemUiMode.edgeToEdge, <DeviceOrientation>[]]);
    });

    test('重复进入 / 退出无副作用', () async {
      final ui = FakeSystemUi();
      final c = VideoFullscreenController(systemUi: ui);
      await c.exit(phone: true);
      expect(ui.calls, isEmpty);
      await c.enter();
      await c.enter(aspectRatio: 9 / 16);
      expect(c.landscape, isTrue);
      expect(ui.calls, hasLength(2));
    });

    test('restore：进入过全屏才恢复系统栏与方向', () async {
      final ui = FakeSystemUi();
      final c = VideoFullscreenController(systemUi: ui);
      await c.restore();
      expect(ui.calls, isEmpty);

      await c.enter();
      ui.calls.clear();
      await c.restore();
      expect(c.isFullscreen, isFalse);
      expect(ui.calls, [SystemUiMode.edgeToEdge, <DeviceOrientation>[]]);
    });

    test('isTouchVideoPlatform', () {
      expect(isTouchVideoPlatform(TargetPlatform.android), isTrue);
      expect(isTouchVideoPlatform(TargetPlatform.iOS), isTrue);
      expect(isTouchVideoPlatform(TargetPlatform.windows), isFalse);
    });
  });

  group('VideoPlayerLayout', () {
    testWidgets('全屏时隐藏标题栏与面板并保留播放器状态；返回键先退出全屏再离开页面', (tester) async {
      final ui = FakeSystemUi();
      final controller = VideoFullscreenController(systemUi: ui);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => _Page(controller: controller),
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      expect(find.text('标题栏'), findsOneWidget);
      expect(find.text('选集面板'), findsOneWidget);

      await tester.tap(find.text('播放器 0'));
      await tester.pump();
      expect(find.text('播放器 1'), findsOneWidget);

      await controller.enter(aspectRatio: 16 / 9);
      await tester.pump();
      expect(find.text('标题栏'), findsNothing);
      expect(find.text('选集面板'), findsNothing);
      expect(find.text('播放器 1'), findsOneWidget); // 状态保留

      // 返回键：只退出全屏。
      ui.calls.clear();
      expect(await tester.binding.handlePopRoute(), isTrue);
      await tester.pumpAndSettle();
      expect(controller.isFullscreen, isFalse);
      expect(find.text('标题栏'), findsOneWidget);
      expect(find.text('播放器 1'), findsOneWidget);
      expect(ui.calls, [SystemUiMode.edgeToEdge, portraitOrientations]);

      // 再按：离开页面，恢复方向限制。
      ui.calls.clear();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('打开'), findsOneWidget);
      expect(ui.calls, [SystemUiMode.edgeToEdge, <DeviceOrientation>[]]);
    });

    testWidgets('宽屏时面板在右侧', (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = VideoFullscreenController(systemUi: FakeSystemUi());
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(home: _Page(controller: controller)));
      final player = tester.getTopLeft(find.text('播放器 0'));
      final panel = tester.getTopLeft(find.text('选集面板'));
      expect(panel.dx, greaterThan(player.dx));
    });
  });

  group('VideoBackgroundPause', () {
    testWidgets('切到后台时暂停一次，回到前台不自动播放；inactive 不算', (tester) async {
      var paused = 0;
      var enabled = true;
      final b = VideoBackgroundPause(
        enabled: () => enabled,
        onBackground: () => paused++,
      )..attach();
      addTearDown(b.detach);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      expect(paused, 0);
      expect(b.inBackground, isFalse);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(paused, 1);
      expect(b.inBackground, isTrue);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      expect(b.inBackground, isTrue);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(b.inBackground, isFalse);
      expect(paused, 1);

      enabled = false;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      expect(paused, 1);
      expect(b.inBackground, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });
  });
}
