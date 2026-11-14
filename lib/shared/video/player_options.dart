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
  // 只用内存缓存：media_kit 默认开启的磁盘缓存在 Windows / Android 上都建不起来
  // （日志 “Failed to create file cache”）。
  'cache-on-disk': 'no',
};

/// 打开 [url]，视频输出就绪后从头开始播放。
///
/// Android 上 media_kit 在拿到视频参数之后才创建 Surface；Surface 到达时它会重新初始化输出并
/// seek 到“当前位置”。这次 seek 落在 HLS 解复用器初始化期间，真机上常常停在分片边界或结尾
/// （首个进度 2.05 / 4.09 / 6.04 s），之后再 seek 到 0 也不生效（Windows 上同样的 seek 正常，无法复现）。
/// 因此不靠 seek 修正，而是：
///
/// 1. 暂停状态打开；
/// 2. 打开时视频输出尚未就绪的，等它就绪（最多 [timeout]）并稍候 [settle]，让上述重新初始化完成；
/// 3. **重新打开**同一地址：Surface 尺寸不变，media_kit 不会再创建 Surface、也不会再 seek，
///    新的解复用器从头读取（代理缓存了解密后的分片，几乎不增加网络请求）；
/// 4. 开始播放。
///
/// 打开时视频输出已就绪（如 Windows）则不重新打开。[alwaysReopen] 只用于在桌面上测试第 3 步。
/// [log] 接收每一步的状态（诊断用）。
Future<void> openWhenVideoReady(
  Player player,
  VideoController video,
  String url, {
  Duration timeout = const Duration(seconds: 5),
  Duration settle = const Duration(milliseconds: 500),
  bool Function()? stillCurrent,
  void Function(String message)? log,
  bool alwaysReopen = false,
}) async {
  bool current() => stillCurrent == null || stillCurrent();
  String state() =>
      'position=${player.state.position} duration=${player.state.duration} '
      'completed=${player.state.completed}';

  final outputWasReady = video.id.value != null;
  await player.open(Media(url), play: false);
  if (!outputWasReady || alwaysReopen) {
    await waitForVideoOutput(video.id, timeout: timeout);
    if (!current()) return;
    log?.call('video output ready (id=${video.id.value}): ${state()}');
    await Future<void>.delayed(settle);
    if (!current()) return;
    log?.call('reopen: ${state()}');
    await player.open(Media(url), play: false);
    if (!current()) return;
  }
  if (needsRestart(player.state.position, completed: player.state.completed)) {
    // 诊断：重新打开后仍不在开头（不应出现）。
    log?.call('unexpected start position: ${state()}');
  }
  await player.play();
  log?.call('play: ${state()}');
}

/// 是否已离开开头：已到结尾，或位置离开头超过 [tolerance]（诊断用）。
bool needsRestart(
  Duration position, {
  required bool completed,
  Duration tolerance = const Duration(milliseconds: 500),
}) => completed || position > tolerance;

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

/// 应用 [videoPlayerMpvOptions]。
Future<void> hardenVideoPlayer(Player player) async {
  if (player.platform case final NativePlayer native) {
    for (final MapEntry(:key, :value) in videoPlayerMpvOptions.entries) {
      await native.setProperty(key, value);
    }
  }
}
