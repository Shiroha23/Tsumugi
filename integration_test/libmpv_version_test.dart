// Windows 随包的 libmpv 是本项目自建的版本（architecture §6.4.6 第 2 项），且 media_kit 与本项目设置的
// mpv 选项在该版本中都生效。
//
//   flutter test integration_test/libmpv_version_test.dart -d windows
//
// 其他平台仍用 media_kit 插件固定的旧版本（第 2 步再换），只打印版本。

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:tsumugi/shared/video/player_options.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  testWidgets('libmpv 版本与选项', (tester) async {
    final player = createVideoPlayer();
    try {
      final native = player.platform! as NativePlayer;
      await native.waitForPlayerInitialization;
      await hardenVideoPlayer(player);
      final mpv = await native.getProperty('mpv-version');
      final ffmpeg = await native.getProperty('ffmpeg-version');
      debugPrint('mpv-version=$mpv ffmpeg-version=$ffmpeg');
      if (!Platform.isWindows) return;

      expect(mpv, startsWith('mpv v0.42.'));
      expect(ffmpeg, startsWith('8.1.'));

      // media_kit 在创建播放器时设置的选项（media_kit 1.2.6 real.dart）与本项目的 videoPlayerMpvOptions。
      // 选项在新版中被改名 / 删除时，mpv 拒绝设置，读回的就不是这里的值。
      // 不检查 osc / ytdl：这两个选项只在启用 Lua 时存在，自建构建（与 2023 版相同）不带 Lua。
      const expected = {
        'idle': 'yes',
        'keep-open': 'yes',
        'audio-display': 'no',
        'network-timeout': '5.000000',
        'scale': 'bilinear',
        'dscale': 'bilinear',
        'dither': 'no',
        'cache': 'yes',
        'hr-seek': 'yes',
        'hr-seek-framedrop': 'no',
        'correct-downscaling': 'no',
        'linear-downscaling': 'no',
        'sigmoid-upscaling': 'no',
        'hdr-compute-peak': 'no',
        'subs-fallback': 'yes',
        'subs-with-matching-audio': 'yes',
        'osd-level': '0',
        'title': 'Tsumugi',
        'sub-ass': 'no',
        'sub-visibility': 'no',
        'secondary-sub-visibility': 'no',
        'sub-auto': 'no',
        'audio-file-auto': 'no',
        'cover-art-auto': 'no',
        'cache-on-disk': 'no',
      };
      final actual = {
        for (final name in expected.keys) name: await native.getProperty(name),
      };
      expect(actual, expected);
      final lavf = await native.getProperty('demuxer-lavf-o');
      expect(lavf, contains('protocol_whitelist=[http,tcp]'));
      expect(lavf, contains('seg_max_retry=5'));
      expect(
        int.parse(await native.getProperty('demuxer-max-bytes')),
        greaterThan(0),
      );
    } finally {
      await player.dispose();
    }
  });
}
