import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// 是否使用触控控件与页面内全屏（Android / iOS）；桌面沿用 media_kit 的桌面控件。
bool isTouchVideoPlatform(TargetPlatform platform) =>
    platform == TargetPlatform.android || platform == TargetPlatform.iOS;

/// 系统栏与屏幕方向（[SystemChrome]）；widget 测试中替换为假实现。
abstract interface class VideoSystemUi {
  Future<void> setSystemUiMode(SystemUiMode mode);
  Future<void> setOrientations(List<DeviceOrientation> orientations);
}

class PlatformVideoSystemUi implements VideoSystemUi {
  const PlatformVideoSystemUi();

  @override
  Future<void> setSystemUiMode(SystemUiMode mode) =>
      SystemChrome.setEnabledSystemUIMode(mode);

  @override
  Future<void> setOrientations(List<DeviceOrientation> orientations) =>
      SystemChrome.setPreferredOrientations(orientations);
}

const landscapeOrientations = [
  DeviceOrientation.landscapeLeft,
  DeviceOrientation.landscapeRight,
];
const portraitOrientations = [DeviceOrientation.portraitUp];

/// 最短边小于此值（dp）视为手机：退出全屏时锁回竖屏。
const phoneShortestSide = 600.0;

/// 移动端页面内全屏（architecture §5.2「移动端全屏」）。
///
/// 进入：系统栏 `immersiveSticky`；宽 ≥ 高（或尺寸未知）时锁定横屏，否则锁定竖屏。
/// 退出：系统栏 `edgeToEdge`，手机锁回竖屏、平板不限制方向。
/// [restore]（离开页面）：恢复系统栏并解除方向限制；从未进入过全屏时什么也不做。
class VideoFullscreenController extends ChangeNotifier {
  VideoFullscreenController({this.systemUi = const PlatformVideoSystemUi()});

  final VideoSystemUi systemUi;

  bool _fullscreen = false;
  bool _touched = false;
  bool? _landscape;

  bool get isFullscreen => _fullscreen;

  /// 当前全屏是否为横屏；未全屏时为 null。
  bool? get landscape => _fullscreen ? _landscape : null;

  /// [aspectRatio] 为视频宽 / 高，未知时为 null（按横屏处理）。
  Future<void> enter({double? aspectRatio}) async {
    if (_fullscreen) return;
    final landscape = aspectRatio == null || aspectRatio >= 1;
    _fullscreen = true;
    _touched = true;
    _landscape = landscape;
    notifyListeners();
    await systemUi.setSystemUiMode(SystemUiMode.immersiveSticky);
    await systemUi.setOrientations(
      landscape ? landscapeOrientations : portraitOrientations,
    );
  }

  /// [phone] 为 true 时锁回竖屏，否则不限制方向。
  Future<void> exit({required bool phone}) async {
    if (!_fullscreen) return;
    _fullscreen = false;
    notifyListeners();
    await systemUi.setSystemUiMode(SystemUiMode.edgeToEdge);
    await systemUi.setOrientations(phone ? portraitOrientations : const []);
  }

  /// 离开页面时调用（可在 dispose 中调用，不通知监听者）。
  Future<void> restore() async {
    if (!_touched) return;
    _fullscreen = false;
    _touched = false;
    await systemUi.setSystemUiMode(SystemUiMode.edgeToEdge);
    await systemUi.setOrientations(const []);
  }
}

/// 应用切到后台时暂停（architecture §5.2「切到后台」）：`hidden` / `paused` / `detached` 时调用 [onBackground]；
/// 回到前台不自动播放。[inBackground] 供加载完成时判断是否应立即暂停。
class VideoBackgroundPause with WidgetsBindingObserver {
  VideoBackgroundPause({required this.enabled, required this.onBackground});

  /// 返回 false 时（桌面）不处理。
  final bool Function() enabled;
  final VoidCallback onBackground;

  bool _inBackground = false;

  bool get inBackground => _inBackground;

  void attach() => WidgetsBinding.instance.addObserver(this);

  void detach() => WidgetsBinding.instance.removeObserver(this);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!enabled()) return;
    switch (state) {
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        if (!_inBackground) {
          _inBackground = true;
          onBackground();
        }
      case AppLifecycleState.resumed:
        _inBackground = false;
      case AppLifecycleState.inactive:
        break;
    }
  }
}
