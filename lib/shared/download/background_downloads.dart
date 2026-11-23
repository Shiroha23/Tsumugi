import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'download_manager.dart';
import 'download_repository.dart';

/// 平台一侧的后台下载支持（architecture §4.5.1「后台下载」）。下载本身仍在 Dart 中执行
/// （同一个 isolate 与网络层），平台只负责让进程在后台继续运行：
///
/// - Android：前台服务（`foregroundServiceType="dataSync"`）与常驻通知（总进度、「暂停全部」）；
/// - iOS：`beginBackgroundTask` 的宽限时间（通常约 30 s）。
abstract interface class BackgroundDownloadPlatform {
  /// Android：启动或更新前台服务的通知。[progress] 为 0–1，未知时为 null。
  Future<void> show({required String text, double? progress});

  /// Android：停止前台服务。
  Future<void> hide();

  /// Android 13+：请求通知权限（拒绝时仍可下载，只是没有通知）。
  Future<void> requestNotificationPermission();

  /// iOS：开始后台任务，返回剩余的宽限时间；不支持或失败时为 null。
  Future<Duration?> beginBackgroundTask();

  /// iOS：结束后台任务。
  Future<void> endBackgroundTask();

  /// 平台事件。
  Stream<BackgroundDownloadEvent> get events;
}

enum BackgroundDownloadEvent {
  /// 通知中的「暂停全部」。
  pauseAll,

  /// Android 15+：`dataSync` 前台服务达到每日时限，被系统停止。
  timeout,

  /// iOS：后台宽限时间即将到期（系统的到期回调）。
  expiring,
}

/// 经 `MethodChannel` 与 `MainActivity` / `AppDelegate` 中的原生实现通信（不引入第三方插件）。
class MethodChannelBackgroundDownloadPlatform
    implements BackgroundDownloadPlatform {
  MethodChannelBackgroundDownloadPlatform([MethodChannel? channel])
    : _channel = channel ?? const MethodChannel(channelName) {
    _channel.setMethodCallHandler((call) async {
      final event = switch (call.method) {
        'pauseAll' => BackgroundDownloadEvent.pauseAll,
        'timeout' => BackgroundDownloadEvent.timeout,
        'expiring' => BackgroundDownloadEvent.expiring,
        _ => null,
      };
      if (event != null) _events.add(event);
    });
  }

  static const channelName = 'io.github.tsumugi/background_download';

  final MethodChannel _channel;
  final _events = StreamController<BackgroundDownloadEvent>.broadcast();

  @override
  Stream<BackgroundDownloadEvent> get events => _events.stream;

  Future<T?> _call<T>(String method, [Object? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      debugPrint('[background_download] $method: $e');
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<void> show({required String text, double? progress}) =>
      _call<void>('show', {
        'text': text,
        // 千分比；-1 表示进度未知。
        'progress': progress == null ? -1 : (progress * 1000).round(),
      });

  @override
  Future<void> hide() => _call<void>('hide');

  @override
  Future<void> requestNotificationPermission() =>
      _call<void>('requestNotificationPermission');

  @override
  Future<Duration?> beginBackgroundTask() async {
    final seconds = await _call<double>('beginBackgroundTask');
    if (seconds == null || !seconds.isFinite || seconds < 0) return null;
    return Duration(milliseconds: (seconds * 1000).round());
  }

  @override
  Future<void> endBackgroundTask() => _call<void>('endBackgroundTask');
}

/// 不需要后台支持的平台（Windows：桌面应用不会被挂起）。
class NoopBackgroundDownloadPlatform implements BackgroundDownloadPlatform {
  const NoopBackgroundDownloadPlatform();

  @override
  Future<void> show({required String text, double? progress}) async {}

  @override
  Future<void> hide() async {}

  @override
  Future<void> requestNotificationPermission() async {}

  @override
  Future<Duration?> beginBackgroundTask() async => null;

  @override
  Future<void> endBackgroundTask() async {}

  @override
  Stream<BackgroundDownloadEvent> get events => const Stream.empty();
}

/// 当前平台的实现：Android / iOS 用原生通道，其余为空实现。
BackgroundDownloadPlatform defaultBackgroundDownloadPlatform() =>
    !kIsWeb && (Platform.isAndroid || Platform.isIOS)
    ? MethodChannelBackgroundDownloadPlatform()
    : const NoopBackgroundDownloadPlatform();

/// 把下载队列接到平台的后台支持上（漫画 / 小说 / 视频共用同一队列，#74）。
///
/// - Android：队列中有可进行的任务（`queued` / `running`）时显示前台服务通知，清空或全部暂停时停止；
///   第一次显示前请求通知权限（Android 13+）。「暂停全部」→ [DownloadManager.pauseAll]。
///   Android 15 的 `dataSync` 时限到、服务被系统停止 → 在后台时挂起队列（[DownloadManager.suspend]），回到前台继续。
/// - iOS：进入后台时开始后台任务，宽限时间到期前 [safetyMargin] 挂起队列（进行中的记为 `queued`）并结束任务；
///   系统提前发出到期通知时同样处理；回到前台继续。
class BackgroundDownloadController with WidgetsBindingObserver {
  BackgroundDownloadController({
    required this.manager,
    required this.repository,
    required this.platform,
    required this.usesBackgroundTask,
    this.safetyMargin = const Duration(seconds: 5),
    this.updateInterval = const Duration(seconds: 1),
  });

  final DownloadManager manager;
  final DownloadRepository repository;
  final BackgroundDownloadPlatform platform;

  /// iOS：没有常驻通知，只在进入后台时申请宽限时间。
  final bool usesBackgroundTask;
  final Duration safetyMargin;

  /// 通知更新的最小间隔。
  final Duration updateInterval;

  StreamSubscription<List<DownloadUnit>>? _units;
  StreamSubscription<BackgroundDownloadEvent>? _events;
  List<DownloadUnit> _latest = const [];
  bool _shown = false;
  bool _askedPermission = false;
  bool _inBackground = false;
  bool _taskActive = false;
  Timer? _expiry;
  DateTime? _lastUpdate;
  Timer? _pendingUpdate;
  bool _disposed = false;

  void attach() {
    WidgetsBinding.instance.addObserver(this);
    _units = repository.watchAllUnits().listen(_onUnits);
    _events = platform.events.listen(_onEvent);
  }

  Future<void> dispose() async {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _expiry?.cancel();
    _pendingUpdate?.cancel();
    await _units?.cancel();
    await _events?.cancel();
    if (_shown) await platform.hide();
    if (_taskActive) await platform.endBackgroundTask();
  }

  /// 可进行的任务（排队或下载中）。
  static List<DownloadUnit> activeOf(List<DownloadUnit> units) => [
    for (final u in units)
      if (u.status == DownloadStatus.queued ||
          u.status == DownloadStatus.running)
        u,
  ];

  /// 通知文字与总进度（下载中的 unit 已完成文件数之和 / 总数之和）。
  static (String, double?) describe(List<DownloadUnit> active) {
    final running = [
      for (final u in active)
        if (u.status == DownloadStatus.running) u,
    ];
    final total = running.fold(0, (n, u) => n + u.totalFiles);
    final done = running.fold(0, (n, u) => n + u.completedFiles);
    final text = running.isEmpty
        ? '排队中：${active.length} 项'
        : '正在下载 ${running.length} 项，剩余 ${active.length} 项';
    return (text, total > 0 ? (done / total).clamp(0.0, 1.0) : null);
  }

  void _onUnits(List<DownloadUnit> units) {
    _latest = units;
    _update();
  }

  void _update() {
    if (_disposed || usesBackgroundTask) return;
    final active = activeOf(_latest);
    if (active.isEmpty || manager.suspended) {
      _pendingUpdate?.cancel();
      _pendingUpdate = null;
      if (_shown) {
        _shown = false;
        platform.hide().ignore();
      }
      return;
    }
    final now = DateTime.now();
    final last = _lastUpdate;
    if (_shown && last != null && now.difference(last) < updateInterval) {
      _pendingUpdate ??= Timer(updateInterval - now.difference(last), () {
        _pendingUpdate = null;
        _update();
      });
      return;
    }
    _lastUpdate = now;
    if (!_askedPermission) {
      _askedPermission = true;
      platform.requestNotificationPermission().ignore();
    }
    _shown = true;
    final (text, progress) = describe(active);
    platform.show(text: text, progress: progress).ignore();
  }

  void _onEvent(BackgroundDownloadEvent e) {
    switch (e) {
      case BackgroundDownloadEvent.pauseAll:
        manager.pauseAll().ignore();
      case BackgroundDownloadEvent.timeout:
        // 前台服务已被系统停止。在后台时进程随时可能被挂起：挂起队列，回到前台继续。
        _shown = false;
        if (_inBackground) {
          manager.suspend().ignore();
        }
      case BackgroundDownloadEvent.expiring:
        _suspendForBackground();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused || AppLifecycleState.hidden:
        if (_inBackground) return;
        _inBackground = true;
        if (usesBackgroundTask) _beginBackgroundTask().ignore();
      case AppLifecycleState.resumed:
        _inBackground = false;
        _expiry?.cancel();
        _expiry = null;
        if (_taskActive) {
          _taskActive = false;
          platform.endBackgroundTask().ignore();
        }
        manager.resumeQueue();
        _update();
      case AppLifecycleState.inactive || AppLifecycleState.detached:
        break;
    }
  }

  Future<void> _beginBackgroundTask() async {
    if (activeOf(_latest).isEmpty || _taskActive) return;
    _taskActive = true;
    final remaining = await platform.beginBackgroundTask();
    if (!_inBackground || !_taskActive) return;
    if (remaining == null) {
      // 拿不到宽限时间：立即挂起，避免被系统挂起时请求半途中断。
      _suspendForBackground();
      return;
    }
    final wait = remaining - safetyMargin;
    _expiry = Timer(
      wait.isNegative ? Duration.zero : wait,
      _suspendForBackground,
    );
  }

  void _suspendForBackground() {
    _expiry?.cancel();
    _expiry = null;
    manager.suspend().whenComplete(() {
      if (_taskActive) {
        _taskActive = false;
        platform.endBackgroundTask().ignore();
      }
    }).ignore();
  }
}
