// 进程环境变量 http_proxy 不能让 libmpv（FFmpeg 的 http 协议）把播放请求发给别的代理
// （architecture §6.4.6 第 2 项：Windows 自建 libmpv 带补丁 ffmpeg-8.1.3-no-env-http-proxy.patch）。
//
//   flutter test integration_test/libmpv_env_proxy_test.dart -d windows
//
// 只在 Windows 上运行：Android / iOS 仍用 media_kit 插件固定的 FFmpeg 6.0，它会读取 http_proxy（第 2 步修复）。
// 环境变量用 UCRT 的 _wputenv_s 设置（libmpv-2.dll 与 Dart 进程共用 ucrtbase 的环境副本）；
// 不能在启动 flutter 前设置，因为 flutter 工具自己连接测试进程时也会走 http_proxy。

import 'dart:ffi';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:tsumugi/core/network/dio_source_http_client.dart';
import 'package:tsumugi/core/network/media/media_proxy.dart';
import 'package:tsumugi/core/network/source_http_client.dart';
import 'package:tsumugi/shared/video/player_options.dart';

import 'test_mock.dart';

typedef _PutEnvNative = Int32 Function(Pointer<Uint16>, Pointer<Uint16>);
typedef _PutEnvDart = int Function(Pointer<Uint16>, Pointer<Uint16>);
typedef _MallocNative = Pointer<Void> Function(IntPtr);
typedef _MallocDart = Pointer<Void> Function(int);
typedef _FreeNative = Void Function(Pointer<Void>);
typedef _FreeDart = void Function(Pointer<Void>);

void _setCrtEnv(String name, String value) {
  final crt = DynamicLibrary.open('ucrtbase.dll');
  final putenv = crt.lookupFunction<_PutEnvNative, _PutEnvDart>('_wputenv_s');
  final malloc = crt.lookupFunction<_MallocNative, _MallocDart>('malloc');
  final free = crt.lookupFunction<_FreeNative, _FreeDart>('free');
  Pointer<Uint16> wide(String s) {
    final units = s.codeUnits;
    final p = malloc((units.length + 1) * 2).cast<Uint16>();
    for (var i = 0; i < units.length; i++) {
      p[i] = units[i];
    }
    p[units.length] = 0;
    return p;
  }

  final n = wide(name);
  final v = wide(value);
  try {
    expect(putenv(n, v), 0, reason: '_wputenv_s($name)');
  } finally {
    free(n.cast());
    free(v.cast());
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  for (final (name, path) in [
    ('MP4', '/video/media/clip.mp4'),
    ('HLS（主 / 子播放列表、分片、字幕轨）', '/video/media/hls/master_sub.m3u8'),
  ]) {
    testWidgets('环境变量 http_proxy 不影响播放器：$name', (tester) async {
      final server = await TestMock.start();
      final client = DioSourceHttpClient(
        SourceNetworkConfig(
          sourceId: 'com.example.video',
          baseUrl: Uri.parse('http://video.example.com'),
          timeout: const Duration(seconds: 5),
        ),
        adapter: server.adapter(),
      );
      final proxy = await MediaProxy.start(log: (m) {});
      // 假的“环境代理”：只记录收到的连接。
      final fake = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      var connections = 0;
      fake.listen((s) {
        connections++;
        s.destroy();
      });
      _setCrtEnv('http_proxy', 'http://127.0.0.1:${fake.port}');
      final player = createVideoPlayer();
      final controller = createVideoController(player);
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: Video(controller: controller)),
          ),
        );
        await hardenVideoPlayer(player);
        final session = proxy.open(
          client: client,
          url: Uri.parse('http://video.example.com$path'),
        );
        final completed = player.stream.completed.firstWhere((c) => c);
        await openVideo(player, controller, session.url.toString());
        await completed.timeout(const Duration(seconds: 20));
        expect(player.state.duration.inMilliseconds, closeTo(6000, 300));
        expect(connections, 0, reason: '播放器不应连接环境变量中的代理');
        session.close();
      } finally {
        _setCrtEnv('http_proxy', '');
        await player.dispose();
        await tester.pumpWidget(const SizedBox());
        await fake.close();
        await proxy.close();
        client.close();
        await server.close();
      }
    }, skip: !Platform.isWindows);
  }
}
