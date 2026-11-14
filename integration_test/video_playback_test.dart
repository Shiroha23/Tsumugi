// M4 视频技术验证：真实的 libmpv 经本地媒体代理播放 mock 服务器上的自制测试视频
// （architecture §6.4）。只在桌面上运行（mock 服务器从工作目录读取 test/fixtures/）：
//
//   flutter test integration_test/video_playback_test.dart -d windows
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:tsumugi/core/network/dio_source_http_client.dart';
import 'package:tsumugi/core/network/media/media_proxy.dart';
import 'package:tsumugi/core/network/source_http_client.dart';
import 'package:tsumugi/shared/video/player_options.dart';

import '../test/core/network/mock_support.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  late MockServer server;
  late DioSourceHttpClient client;
  late MediaProxy proxy;

  setUp(() async {
    server = await MockServer.start();
    client = mockClient(
      server,
      sourceId: 'com.example.video',
      baseUrl: 'http://video.example.com',
      allowedHosts: const [],
      headers: {'User-Agent': 'TsumugiVideoTest'},
    );
    proxy = await MediaProxy.start();
  });
  tearDown(() async {
    await proxy.close();
    client.close();
    await server.close();
  });

  /// 播放到结束，返回 (画面宽, 高, 时长)。
  Future<(int?, int?, Duration)> playToEnd(WidgetTester tester, Uri url) async {
    final player = createVideoPlayer();
    final controller = VideoController(player);
    final errors = <String>[];
    final sub = player.stream.error.listen(errors.add);
    // libmpv 的错误日志（失败时便于排查）。
    final logs = player.stream.log.listen((l) => debugPrint('mpv: $l'));
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: Video(controller: controller)),
        ),
      );
      await hardenVideoPlayer(player);
      await player.setRate(2);
      final completed = player.stream.completed.firstWhere((c) => c);
      await player.open(Media(url.toString()));

      // 进度：播放中途暂停再继续，再跳到 4 s。
      await player.stream.position
          .firstWhere((p) => p > const Duration(seconds: 1))
          .timeout(const Duration(seconds: 20));
      await player.pause();
      expect(player.state.playing, isFalse);
      await player.seek(const Duration(seconds: 4));
      await player.play();

      await completed.timeout(const Duration(seconds: 30));
      expect(errors, isEmpty);
      return (player.state.width, player.state.height, player.state.duration);
    } finally {
      debugPrint('errors: $errors');
      await sub.cancel();
      await logs.cancel();
      await player.dispose();
      await tester.pumpWidget(const SizedBox());
    }
  }

  void expectOnlyThroughSource() {
    final video = server.requests.where((r) => r.path.startsWith('/video/'));
    expect(video, isNotEmpty);
    // 每个请求都经源客户端：虚构主机名、源的 UA，没有 libmpv 自己的 UA。
    expect(video.map((r) => r.host).toSet(), {'video.example.com'});
    expect(video.map((r) => r.headers['user-agent']).toSet(), {
      'TsumugiVideoTest',
    });
  }

  testWidgets('MP4', (tester) async {
    final session = proxy.open(
      client: client,
      url: Uri.parse('http://video.example.com/video/media/clip.mp4'),
    );
    final (w, h, duration) = await playToEnd(tester, session.url);
    expect((w, h), (320, 180));
    expect(duration.inMilliseconds, closeTo(6000, 200));
    expectOnlyThroughSource();
    session.close();
  });

  testWidgets('HLS（AES-128，需要 Referer 与 Cookie）', (tester) async {
    await client.getText('/video/show/1'); // 站点种下 vtoken Cookie
    final session = proxy.open(
      client: client,
      url: Uri.parse(
        'http://video.example.com/video/protected/hls/master.m3u8',
      ),
      headers: {'Referer': 'http://video.example.com/video/show/1'},
    );
    final (w, h, duration) = await playToEnd(tester, session.url);
    expect((w, h), (320, 180));
    expect(duration.inMilliseconds, closeTo(6000, 300));
    expectOnlyThroughSource();
    // 密钥由代理取得并解密（FFmpeg 的协议白名单中没有 crypto）。
    final paths = server.requests.map((r) => r.path).toSet();
    expect(
      paths,
      containsAll([
        '/video/protected/hls/master.m3u8',
        '/video/protected/hls/index.m3u8',
        '/video/protected/hls/key.bin',
        '/video/protected/hls/seg0.ts',
        '/video/protected/hls/seg2.ts',
      ]),
    );
    expect(
      server.requests
          .where((r) => r.path.startsWith('/video/protected/'))
          .map((r) => r.headers['referer'])
          .toSet(),
      {'http://video.example.com/video/show/1'},
    );
    session.close();
  });
}
