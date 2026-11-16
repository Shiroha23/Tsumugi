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

/// 从 [start] 开始播放 [url]（[start] 为 0 时从头开始；mpv 的 `start` 选项，media_kit 在 unload 时清除）。
///
/// Android 上 media_kit 拿到视频参数后才创建 Surface，到达时重新初始化输出并 seek 到“当前位置”；
/// HLS 初始化期间的这次 seek 曾让播放停在分片边界或结尾。依赖的 media_kit_video fork 在位置 ≤ 0
/// 或已播完时不执行这次 seek（#39，architecture §6.4.2），因此这里直接打开，不再等待视频输出或重新打开。
Future<void> openVideo(
  Player player,
  String url, {
  Duration start = Duration.zero,
}) => player.open(Media(url, start: start > Duration.zero ? start : null));

/// 等到播放器真正从 [start] 开始播放（播放页在此之前用加载遮罩盖住画面并隐藏控件）：
/// 位置越过 0 且不早于 `start - tolerance`。播放完成、出错（[failed]）或超过 [timeout]
/// 时同样返回，遮罩不会一直留着。须在 `open` 之前调用，以免漏掉事件。
Future<void> waitForPlaybackStart({
  required Stream<Duration> position,
  required Stream<bool> completed,
  Stream<Object?>? failed,
  Duration start = Duration.zero,
  Duration tolerance = const Duration(seconds: 2),
  Duration timeout = const Duration(seconds: 20),
}) {
  final done = Completer<void>();
  final subscriptions = <StreamSubscription<Object?>>[];
  void finish([Object? _]) {
    if (!done.isCompleted) done.complete();
  }

  subscriptions
    ..add(
      position.listen((p) {
        if (hasStartedAt(p, start, tolerance: tolerance)) finish();
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
