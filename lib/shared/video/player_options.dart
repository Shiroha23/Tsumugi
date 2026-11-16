import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// 创建播放器（libmpv）。FFmpeg 只允许 http（经本地媒体代理，architecture §6.4）与其下层的 tcp；
/// 不允许 file / https / udp / rtmp / crypto 等协议（HLS AES-128 由代理解密）。
Player createVideoPlayer() => Player(
  configuration: const PlayerConfiguration(
    title: 'Tsumugi',
    protocolWhitelist: ['http', 'tcp'],
    // 警告及以上的 libmpv 日志（播放页经 debugPrint 输出，便于真机排查）。
    logLevel: MPVLogLevel.warn,
  ),
);

/// 详细的视频诊断日志（代理的逐个请求、播放器状态、实际解码路径）：debug 构建默认开启，
/// release 构建用 `--dart-define=TSUMUGI_VIDEO_LOG=true` 开启。关闭时只输出 libmpv 的警告 / 错误、
/// 代理的失败原因与每次播放一行的启动摘要。
const videoVerboseLogs =
    kDebugMode || bool.fromEnvironment('TSUMUGI_VIDEO_LOG');

/// 诊断用：`--dart-define=TSUMUGI_HWDEC=<mpv 的 hwdec 取值>`（如 `no`、`mediacodec-copy`、
/// `mediacodec`、`auto-safe`）覆盖 media_kit 的默认值（硬解 `auto-safe`），用于在真机上比较解码路径。
/// 不设置时为空，使用 media_kit 的默认值。
const videoHwdecOverride = String.fromEnvironment('TSUMUGI_HWDEC');

/// 为 [player] 创建视频输出（应用 [videoHwdecOverride]）。
VideoController createVideoController(Player player) => VideoController(
  player,
  configuration: VideoControllerConfiguration(
    hwdec: videoHwdecOverride.isEmpty ? null : videoHwdecOverride,
  ),
);

/// 播放开始后 libmpv 实际使用的解码设置（诊断日志用）。
Future<String> describeVideoDecoder(Player player) async {
  if (player.platform case final NativePlayer native) {
    final parts = <String>[];
    for (final name in const ['hwdec', 'hwdec-current', 'video-codec', 'vo']) {
      try {
        parts.add('$name=${await native.getProperty(name)}');
      } catch (_) {
        parts.add('$name=?');
      }
    }
    return parts.join(' ');
  }
  return '(not native)';
}

/// 打开媒体前交给 libmpv 的选项（深度防御；主要的边界是代理）。
///
/// 不设 `access-references=no`：media_kit 打开媒体时自己写一个临时播放列表文件再 `loadlist`，
/// 该选项会让它失败。网络上来的 m3u / pls 等播放列表由代理拒绝（只放行经改写的 HLS 播放列表）。
const videoPlayerMpvOptions = {
  // 不在网络地址旁自动寻找外挂字幕 / 音轨 / 封面。
  'sub-auto': 'no',
  'audio-file-auto': 'no',
  'cover-art-auto': 'no',
  // 不调用 youtube-dl / yt-dlp 解析地址。
  'ytdl': 'no',
  // 只用内存缓存（media_kit 的 bufferSize：向前 / 向后各 32 MB）。media_kit 默认开启磁盘缓存但不设
  // cache-dir，在 Windows / Android 上都建不起来（日志 “Failed to create file cache”）；评估后不启用：
  // 它只是同一解复用缓存的后备存储（容量不变、不跨播放保留），且会把解密后的明文落盘（architecture §6.4.3）。
  'cache-on-disk': 'no',
};

/// 从 [start] 开始播放 [url]，返回时已真正开始播放（见 [waitForPlaybackStart]）。
/// [start] 为 0 时从头开始；用 mpv 的 `start` 选项，media_kit 在 unload 时清除。
///
/// Android 上 media_kit 拿到视频参数后才创建 Surface；Surface 到达时把视频输出从 `null` 换成真正的输出
/// 并 seek 到“当前位置”。这一步落在 HLS 解复用器初始化期间时，播放会停在分片边界（2.1 s）或结尾。
/// 只跳过 media_kit 那次 seek 不够（#49：fork 方案在真机上 6 次中仍有 5 次跳位，architecture §6.4.2），
/// 因此：
///
/// - 视频输出已就绪（Windows，或 Android 上同一播放页内换集、Surface 尺寸不变）：直接打开；
/// - 否则先**暂停**打开，等视频输出就绪（[video] 的纹理编号，最多 [surfaceTimeout]，如只有音轨的流）
///   并稍候 [settle]，再**重新打开**同一地址：Surface 尺寸不变，media_kit 不再更换输出、也不再 seek，
///   新的解复用器从 [start] 读取（代理缓存了解密后的分片，几乎不增加网络请求）。
///
/// [stillCurrent] 返回 false 时（页面已关闭或换集）提前返回，不再开始播放。
/// [alwaysReopen] 只用于在桌面上测试重新打开的路径。
Future<void> openVideo(
  Player player,
  VideoController video,
  String url, {
  Duration start = Duration.zero,
  Duration surfaceTimeout = const Duration(seconds: 5),
  Duration settle = const Duration(milliseconds: 500),
  Duration startTimeout = const Duration(seconds: 20),
  bool Function()? stillCurrent,
  bool alwaysReopen = false,
}) async {
  bool current() => stillCurrent == null || stillCurrent();
  Media media() => Media(url, start: start > Duration.zero ? start : null);

  if (video.id.value == null || alwaysReopen) {
    await player.open(media(), play: false);
    await waitForVideoOutput(video.id, timeout: surfaceTimeout);
    if (!current()) return;
    await Future<void>.delayed(settle);
    if (!current()) return;
  }
  // 在最后一次打开之前订阅：第一次（暂停）打开期间的位置 / 完成事件不算。
  final started = waitForPlaybackStart(
    position: player.stream.position,
    completed: player.stream.completed,
    failed: player.stream.error,
    duration: player.stream.duration,
    buffering: player.stream.buffering,
    start: start,
    timeout: startTimeout,
  );
  await player.open(media());
  await started;
}

/// 等待视频输出就绪（[id] 为纹理编号，Android 上与 Surface 一同到达）；
/// 超过 [timeout]（例如只有音轨的流）时直接返回。
Future<void> waitForVideoOutput(
  ValueListenable<int?> id, {
  Duration timeout = const Duration(seconds: 5),
}) {
  if (id.value != null) return Future.value();
  final ready = Completer<void>();
  void listener() {
    if (id.value != null && !ready.isCompleted) ready.complete();
  }

  id.addListener(listener);
  return ready.future
      .timeout(timeout, onTimeout: () {})
      .whenComplete(() => id.removeListener(listener));
}

/// 等到播放器真正从 [start] 开始播放（播放页在此之前用加载遮罩盖住画面并隐藏控件）：
/// 位置越过 0 且不早于 `start - tolerance`。播放完成、出错（[failed]）或超过 [timeout]
/// 时同样返回，遮罩不会一直留着。须在 `open` 之前调用，以免漏掉事件。
///
/// 给出 [duration] / [buffering] 时，订阅之后要先收到新媒体的时长（> 0）或经历一次“缓冲开始 → 结束”
/// （直播流没有时长），之后的位置才算数：换集时旧媒体播完后残留的位置（约等于旧时长）会在新媒体
/// 打开期间到达，此时 `player.state.duration` 也可能还是旧值，不能当作新媒体已开始播放（Android 真机上出现过）。
Future<void> waitForPlaybackStart({
  required Stream<Duration> position,
  required Stream<bool> completed,
  Stream<Object?>? failed,
  Stream<Duration>? duration,
  Stream<bool>? buffering,
  Duration start = Duration.zero,
  Duration tolerance = const Duration(seconds: 2),
  Duration timeout = const Duration(seconds: 20),
}) {
  final done = Completer<void>();
  final subscriptions = <StreamSubscription<Object?>>[];
  var armed = duration == null && buffering == null;
  var sawBuffering = false;
  void finish([Object? _]) {
    if (!done.isCompleted) done.complete();
  }

  if (duration != null) {
    subscriptions.add(
      duration.listen((d) {
        if (d > Duration.zero) armed = true;
      }),
    );
  }
  if (buffering != null) {
    subscriptions.add(
      buffering.listen((b) {
        if (b) {
          sawBuffering = true;
        } else if (sawBuffering) {
          armed = true;
        }
      }),
    );
  }
  subscriptions
    ..add(
      position.listen((p) {
        if (armed && hasStartedAt(p, start, tolerance: tolerance)) finish();
      }),
    )
    ..add(
      completed.listen((c) {
        if (c) finish();
      }),
    );
  if (failed != null) subscriptions.add(failed.listen(finish));
  return done.future.timeout(timeout, onTimeout: () {}).whenComplete(() {
    for (final s in subscriptions) {
      s.cancel().ignore();
    }
  });
}

/// 位置 [p] 是否表示已从 [start] 开始播放（见 [waitForPlaybackStart]）。
bool hasStartedAt(
  Duration p,
  Duration start, {
  Duration tolerance = const Duration(seconds: 2),
}) => p > Duration.zero && p >= start - tolerance;

/// 应用 [videoPlayerMpvOptions]。
Future<void> hardenVideoPlayer(Player player) async {
  if (player.platform case final NativePlayer native) {
    for (final MapEntry(:key, :value) in videoPlayerMpvOptions.entries) {
      await native.setProperty(key, value);
    }
  }
}
