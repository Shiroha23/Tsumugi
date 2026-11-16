// M4 视频：真实的 libmpv 经本地媒体代理播放 mock 服务器上的自制测试视频
// （architecture §5.2「视频播放」、§6.4）。只在桌面上运行（mock 服务器从工作目录读取 test/fixtures/）：
//
//   flutter test integration_test/video_playback_test.dart -d windows
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:tsumugi/core/network/dio_source_http_client.dart';
import 'package:tsumugi/core/network/media/media_proxy.dart';
import 'package:tsumugi/core/network/source_http_client.dart';
import 'package:tsumugi/core/storage/app_database.dart';
import 'package:tsumugi/features/video/player/video_player_page.dart';
import 'package:tsumugi/shared/history/providers.dart';
import 'package:tsumugi/shared/video/media_proxy_providers.dart';
import 'package:tsumugi/shared/video/player_options.dart';
import 'package:tsumugi/sources/network_error_mapping.dart';
import 'package:tsumugi/sources/registry/providers.dart';
import 'package:tsumugi/sources/session/source_sessions.dart';

import '../test/core/network/mock_support.dart';
import '../test/core/storage/test_database.dart';
import '../test/sources/runtime/runtime_support.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  late MockServer server;

  setUp(() async => server = await MockServer.start());
  tearDown(() => server.close());

  group('播放器 + 代理', () {
    late DioSourceHttpClient client;
    late MediaProxy proxy;

    setUp(() async {
      client = mockClient(
        server,
        sourceId: 'com.example.video',
        baseUrl: 'http://video.example.com',
        allowedHosts: const [],
        headers: {'User-Agent': 'TsumugiVideoTest'},
      );
      proxy = await MediaProxy.start(
        log: (m) => debugPrint('[media_proxy] $m'),
      );
    });
    tearDown(() async {
      await proxy.close();
      client.close();
    });

    /// 从 [start] 播放到结束，返回 (画面宽, 高, 时长, 开始播放时的位置)。
    Future<(int?, int?, Duration, Duration)> playToEnd(
      WidgetTester tester,
      Uri url, {
      Duration start = Duration.zero,
      bool alwaysReopen = false,
    }) async {
      final player = createVideoPlayer();
      final controller = createVideoController(player);
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
        // 与播放页相同；返回时已真正开始播放。
        await openVideo(
          player,
          controller,
          url.toString(),
          start: start,
          alwaysReopen: alwaysReopen,
        );
        final completed = player.stream.completed.firstWhere((c) => c);
        final startedAt = player.state.position;

        if (start == Duration.zero) {
          // 进度：播放中途暂停再继续，再跳到 4 s。
          await player.stream.position
              .firstWhere((p) => p > const Duration(seconds: 1))
              .timeout(const Duration(seconds: 20));
          await player.pause();
          expect(player.state.playing, isFalse);
          await player.seek(const Duration(seconds: 4));
          await player.play();
        }

        await completed.timeout(const Duration(seconds: 30));
        expect(errors, isEmpty);
        debugPrint('decoder ${await describeVideoDecoder(player)}');
        return (
          player.state.width,
          player.state.height,
          player.state.duration,
          startedAt,
        );
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
      final (w, h, duration, startedAt) = await playToEnd(tester, session.url);
      expect((w, h), (320, 180));
      expect(duration.inMilliseconds, closeTo(6000, 200));
      // 回归：Android 上曾直接跳到结尾（首个进度为 6 s）。
      expect(startedAt, lessThan(const Duration(seconds: 1)));
      expectOnlyThroughSource();
      session.close();
    });

    for (final file in ['clip.ts', 'clip_pts0.ts']) {
      testWidgets('MPEG-TS 单文件（诊断素材）$file', (tester) async {
        final session = proxy.open(
          client: client,
          url: Uri.parse('http://video.example.com/video/media/$file'),
        );
        final (w, h, duration, _) = await playToEnd(tester, session.url);
        expect((w, h), (320, 180));
        expect(duration.inMilliseconds, closeTo(6000, 300));
        session.close();
      });
    }

    testWidgets('HLS：视频输出就绪后重新打开（Android 的路径）也从头播放', (tester) async {
      final session = proxy.open(
        client: client,
        url: Uri.parse('http://video.example.com/video/media/hls/master.m3u8'),
      );
      final (w, h, duration, startedAt) = await playToEnd(
        tester,
        session.url,
        alwaysReopen: true,
      );
      expect((w, h), (320, 180));
      expect(duration.inMilliseconds, closeTo(6000, 300));
      expect(startedAt, lessThan(const Duration(seconds: 1)));
      session.close();
    });

    for (final (name, file) in [
      ('HLS', 'hls/master.m3u8'),
      ('MP4', 'clip.mp4'),
    ]) {
      for (final reopen in [false, true]) {
        testWidgets('$name：从起始位置打开（续播 / 换清晰度）${reopen ? '，重新打开' : ''}', (
          tester,
        ) async {
          final session = proxy.open(
            client: client,
            url: Uri.parse('http://video.example.com/video/media/$file'),
          );
          final (_, _, duration, startedAt) = await playToEnd(
            tester,
            session.url,
            start: const Duration(seconds: 3),
            alwaysReopen: reopen,
          );
          expect(duration.inMilliseconds, closeTo(6000, 300));
          expect(startedAt.inMilliseconds, inInclusiveRange(2000, 4500));
          session.close();
        });
      }
    }

    testWidgets('HLS（AES-128，需要 Referer 与 Cookie）', (tester) async {
      await client.getText('/video/show/1'); // 站点种下 vtoken Cookie
      final session = proxy.open(
        client: client,
        url: Uri.parse(
          'http://video.example.com/video/protected/hls/master.m3u8',
        ),
        headers: {'Referer': 'http://video.example.com/video/show/1'},
      );
      final (w, h, duration, startedAt) = await playToEnd(tester, session.url);
      expect((w, h), (320, 180));
      expect(duration.inMilliseconds, closeTo(6000, 300));
      expect(startedAt, lessThan(const Duration(seconds: 1)));
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
  });

  // 播放页：多线路 / 多清晰度的虚构脚本源（mock 服务器 /video/api/*）。
  group('播放页', () {
    const sourceId = 'com.example.mock.video.script';
    const itemId = '/video/api/show/2';
    late AppDatabase db;
    late ProviderContainer container;

    setUp(() async {
      db = openTestDatabase();
      await SourceRegistry(db).importText(
        File('test/fixtures/sources/mock_video_script.json').readAsStringSync(),
      );
      container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          sessionPersistenceProvider.overrideWithValue(null),
          sourceFactoriesProvider.overrideWithValue(mockFactories(server)),
          mediaProxyClientProvider.overrideWithValue(
            (manifest) => DioSourceHttpClient(
              networkConfigFromManifest(manifest),
              adapter: mockAdapter(server),
            ),
          ),
        ],
      );
    });
    tearDown(() async {
      container.dispose();
      await db.close();
    });

    Future<void> pumpPage(WidgetTester tester, String unitId) =>
        tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              home: VideoPlayerPage(
                sourceId: sourceId,
                itemId: itemId,
                unitId: unitId,
              ),
            ),
          ),
        );

    Future<void> pumpUntil(
      WidgetTester tester,
      bool Function() done, {
      Duration timeout = const Duration(seconds: 30),
      String? reason,
    }) async {
      final end = DateTime.now().add(timeout);
      while (!done()) {
        if (DateTime.now().isAfter(end)) fail('超时：${reason ?? ''}');
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    bool playing() => find.byType(CircularProgressIndicator).evaluate().isEmpty;
    Future<UnitProgress?> unit(String id) => container
        .read(historyRepositoryProvider)
        .unitProgress(sourceId, itemId, id);

    testWidgets('换清晰度保持位置；播完自动下一集；再次打开从上次位置续播', (tester) async {
      const ep1 = '/video/api/play/b/1';
      const ep2 = '/video/api/play/b/2';
      await pumpPage(tester, ep1);
      await pumpUntil(tester, playing, reason: '第 1 集开始播放');
      expect(find.text('第 1 集'), findsWidgets); // 标题栏与选集列表
      expect(find.text('720p'), findsOneWidget);
      expect(find.text('线路 B'), findsOneWidget);

      // 播放到 2 s 左右换到 360p（MP4）。
      await tester.pump(const Duration(seconds: 2));
      await tester.tap(find.byTooltip('清晰度'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('360p').last);
      await tester.pump();
      await pumpUntil(tester, playing, reason: '360p 开始播放');
      expect(
        server.requests.map((r) => r.path),
        contains('/video/media/clip.mp4'),
      );
      final afterSwitch = await tester.runAsync(() => unit(ep1));
      expect(
        afterSwitch!.position,
        greaterThan(1000),
        reason: '换清晰度后从原位置继续（不是从 0 开始）',
      );

      // 播完后自动播放第 2 集，第 1 集标为已看。
      await pumpUntil(
        tester,
        () => find.widgetWithText(AppBar, '第 2 集').evaluate().isNotEmpty,
        reason: '自动下一集',
      );
      await pumpUntil(tester, playing, reason: '第 2 集开始播放');
      final read = await tester.runAsync(() => unit(ep1));
      expect(read!.read, isTrue);
      expect(read.position, 0);
      expect(find.text('360p'), findsOneWidget, reason: '换集沿用清晰度');

      // 看到 2 s 左右离开，再次打开从记录的位置继续。
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 500));
      final saved = (await tester.runAsync(() => unit(ep2)))!.position!;
      expect(saved, greaterThan(1000));

      await pumpPage(tester, ep2);
      await pumpUntil(tester, playing, reason: '续播开始');
      final resumed = (await tester.runAsync(() => unit(ep2)))!.position!;
      expect(resumed, greaterThanOrEqualTo(saved - 2000));
      final latest = await tester.runAsync(
        () => container
            .read(historyRepositoryProvider)
            .latestProgress(sourceId, itemId),
      );
      expect(latest!.unitId, ep2);
      expect(latest.item.coverHeaders, isNull, reason: '没有封面');
      await tester.pumpWidget(const SizedBox());
    });
  });
}
