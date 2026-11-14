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

/// 打开 [url] 并在视频输出就绪后开始播放（暂停状态打开 → [waitForVideoOutput] → 播放）。
///
/// Android 上 media_kit 在拿到视频参数之后才创建 Surface（`VideoOutput.Resize` 带来 `wid`），
/// 之前 MediaCodec 硬解没有输出目标（“Both surface and native_window are NULL”），解不出画面；
/// 没有音轨的短视频会直接播到结尾，界面停在黑屏（真机上 HLS 测试素材常见）。
/// 先暂停打开，等 Surface 就绪后 media_kit 会重新初始化输出并定位到当前位置，再开始播放。
Future<void> openWhenVideoReady(
  Player player,
  VideoController video,
  String url, {
  Duration timeout = const Duration(seconds: 5),
  bool Function()? stillCurrent,
}) async {
  await player.open(Media(url), play: false);
  await waitForVideoOutput(video.id, timeout: timeout);
  if (stillCurrent != null && !stillCurrent()) return;
  await player.play();
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

/// 应用 [videoPlayerMpvOptions]。
Future<void> hardenVideoPlayer(Player player) async {
  if (player.platform case final NativePlayer native) {
    for (final MapEntry(:key, :value) in videoPlayerMpvOptions.entries) {
      await native.setProperty(key, value);
    }
  }
}
