// M4 视频：真实的 libmpv 经本地媒体代理播放 mock 服务器上的自制测试视频
// （architecture §5.2「视频播放」、§6.4）。
//
// Windows（mock 服务器在测试进程内启动，从工作目录读取 test/fixtures/）：
//
//   flutter test integration_test/video_playback_test.dart -d windows
//
// Android 设备（设备读不到电脑的文件：先在电脑上以 --test-control 启动 mock 服务器，测试经局域网连接它）：
//
//   dart run tool/mock_server/main.dart --host 0.0.0.0 --port 8081 --test-control
//   flutter drive --profile --driver=test_driver/integration_test.dart \
//     --target=integration_test/video_playback_test.dart -d <设备> \
//     --dart-define=TSUMUGI_MOCK_SERVER=<电脑局域网 IP>:8081
//
// （profile 模式要用 flutter drive；`flutter test ... -d <设备>` 只支持 debug 模式。）

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
import 'package:tsumugi/shared/video/subtitle_providers.dart';
import 'package:tsumugi/sources/network_error_mapping.dart';
import 'package:tsumugi/sources/registry/providers.dart';
import 'package:tsumugi/sources/session/source_sessions.dart';

import '../test/core/storage/test_database.dart';
import '../test/sources/runtime/runtime_support.dart';
import 'test_mock.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  late TestMock server;

  setUp(() async => server = await TestMock.start());
  tearDown(() => server.close());

  group('播放器 + 代理', () {
    late DioSourceHttpClient client;
    late MediaProxy proxy;

    setUp(() async {
      client = DioSourceHttpClient(
        SourceNetworkConfig(
          sourceId: 'com.example.video',
          baseUrl: Uri.parse('http://video.example.com'),
          defaultHeaders: const {'User-Agent': 'TsumugiVideoTest'},
          timeout: const Duration(seconds: 5),
          retryBaseDelay: const Duration(milliseconds: 10),
        ),
        adapter: server.adapter(),
      );
      proxy = await MediaProxy.start(
        log: (m) => debugPrint('[media_proxy] $m'),
        trace: videoVerboseLogs ? (m) => debugPrint('[media_proxy] $m') : null,
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

    Future<void> expectOnlyThroughSource() async {
      final video = (await server.requests()).where(
        (r) => r.path.startsWith('/video/'),
      );
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
      await expectOnlyThroughSource();
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
      await expectOnlyThroughSource();
      // 密钥由代理取得并解密（FFmpeg 的协议白名单中没有 crypto）。
      final requests = await server.requests();
      final paths = requests.map((r) => r.path).toSet();
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
        requests
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
    late MemorySubtitlePreferencesStore subtitlePrefs;

    setUp(() async {
      db = openTestDatabase();
      subtitlePrefs = MemorySubtitlePreferencesStore();
      await SourceRegistry(db)
          .importText(await server.fixture('sources/mock_video_script.json'));
      container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          sessionPersistenceProvider.overrideWithValue(null),
          subtitlePreferencesStoreProvider.overrideWithValue(subtitlePrefs),
          // 与应用一样，源实例与媒体代理共用该源的会话（Cookie：线路 A 的密钥要求详情页种下的 vtoken）。
          sourceFactoriesProvider.overrideWith(
            (ref) => adapterFactories(
              server.adapter,
              session: ref.read(sourceSessionsProvider).of,
            ),
          ),
          mediaProxyClientProvider.overrideWith(
            (ref) =>
                (manifest) => DioSourceHttpClient(
                  networkConfigFromManifest(manifest),
                  adapter: server.adapter(),
                  session: ref.read(sourceSessionsProvider).of(manifest.id),
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
        (await server.requests()).map((r) => r.path),
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

    // 字幕（architecture §5.2「字幕」、§6.4.7）。
    String subtitleText(WidgetTester tester) {
      final f = find.byKey(const ValueKey('video-subtitle-text'));
      return f.evaluate().isEmpty ? '' : tester.widget<Text>(f).data ?? '';
    }

    Future<void> chooseSubtitle(WidgetTester tester, String label) async {
      await tester.tap(find.byTooltip('字幕'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pump();
    }

    testWidgets('字幕：默认第一条外挂字幕；GBK / ASS；失败退回关闭；HLS 内嵌轨；按源记住', (tester) async {
      await pumpPage(tester, '/video/api/play/b/1');
      await pumpUntil(tester, playing, reason: '开始播放');

      // 没有记录：显示第一条外挂字幕（简体中文，UTF-8 带 BOM 的 srt）。
      await pumpUntil(
        tester,
        () => subtitleText(tester).startsWith('第'),
        reason: '外挂字幕（简体中文）',
      );
      expect(subtitlePrefs.values, isEmpty, reason: '自动选择不记住');

      // GBK 编码的 srt（服务器不带 charset）。
      await chooseSubtitle(tester, '简体中文（GBK）');
      await pumpUntil(
        tester,
        () => subtitleText(tester).startsWith('GBK 字幕：'),
        reason: 'GBK 字幕',
      );
      expect(subtitlePrefs.values[sourceId], const SubtitleLabel('简体中文（GBK）'));

      // 伪装成 srt 的 HTML：提示失败、退回关闭、不记住。
      await chooseSubtitle(tester, '损坏示例');
      await pumpUntil(
        tester,
        () => find.textContaining('加载失败').evaluate().isNotEmpty,
        reason: '失败提示',
      );
      expect(subtitleText(tester), '');
      expect(subtitlePrefs.values[sourceId], const SubtitleLabel('简体中文（GBK）'));

      // HLS 流自带的字幕轨（经代理的 WebVTT 分片）。
      // FFmpeg 不把 EXT-X-MEDIA 的 NAME 作为轨道标题，标签为 LANGUAGE。
      await chooseSubtitle(tester, 'zh（内嵌）');
      await pumpUntil(
        tester,
        () => subtitleText(tester).startsWith('HLS subtitle'),
        reason: 'HLS 内嵌字幕',
      );
      expect(
        (await server.requests()).map((r) => r.path),
        contains('/video/media/hls/sub.m3u8'),
      );
      expect(subtitlePrefs.values[sourceId], const SubtitleLabel('zh'));

      // 播完自动下一集：按记住的标签自动选上新流的内嵌轨（轨道列表在新流开始播放后才确定）。
      await pumpUntil(
        tester,
        () => find.widgetWithText(AppBar, '第 2 集').evaluate().isNotEmpty,
        reason: '自动下一集',
      );
      await pumpUntil(tester, playing, reason: '第 2 集开始播放');
      await pumpUntil(
        tester,
        () => subtitleText(tester).startsWith('HLS subtitle'),
        reason: '下一集自动选上内嵌轨',
      );

      // ASS：覆盖标签与绘图指令被去掉。
      await chooseSubtitle(tester, '日本語');
      await pumpUntil(
        tester,
        () => const {
          '一つ目, comma kept\nnext line',
          '二つ目 です',
          '三つ目',
        }.contains(subtitleText(tester)),
        reason: 'ASS 字幕',
      );
      expect(subtitleText(tester), isNot(contains('{')));
      expect(subtitleText(tester), isNot(contains('m 0 0')));

      // 换清晰度：外挂字幕保持。
      await chooseSubtitle(tester, 'English');
      await tester.tap(find.byTooltip('清晰度'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('360p').last);
      await tester.pump();
      await pumpUntil(tester, playing, reason: '360p 开始播放');
      await pumpUntil(
        tester,
        () => const {
          'Color bars & a tone',
          'Second part still',
          'Last part <end>',
        }.contains(subtitleText(tester)),
        reason: '换清晰度后仍显示 English',
      );
      expect(subtitlePrefs.values[sourceId], const SubtitleLabel('English'));
      await tester.pumpWidget(const SizedBox());

      // 重新打开另一集：按记住的标签选择。
      // 线路 A：需要 Referer 与 Cookie 的 AES-128 HLS。等到第二条字幕出现，确认确实在播放
      // （位置停在 0 时第一条字幕也会显示）。
      await pumpPage(tester, '/video/api/play/a/2');
      await pumpUntil(tester, playing, reason: '另一集开始播放');
      await pumpUntil(
        tester,
        () => subtitleText(tester) == 'Second part still',
        reason: '按记录选 English，且在播放',
      );
      expect(find.textContaining('播放出错'), findsNothing);

      // 页面内换集：仍按记录选 English。
      await tester.tap(find.text('第 3 集').last);
      await tester.pump();
      await pumpUntil(
        tester,
        () => find.widgetWithText(AppBar, '第 3 集').evaluate().isNotEmpty,
        reason: '换到第 3 集',
      );
      await pumpUntil(tester, playing, reason: '第 3 集开始播放');
      await pumpUntil(
        tester,
        () => subtitleText(tester) == 'Second part still',
        reason: '换集后仍显示 English，且在播放',
      );

      // 关闭字幕：不再显示，并记住。
      await chooseSubtitle(tester, '关闭');
      expect(subtitlePrefs.values[sourceId], const SubtitleOff());
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        expect(subtitleText(tester), '', reason: '关闭后不显示字幕');
      }
      await tester.pumpWidget(const SizedBox());

      // 再次打开：按记录保持关闭。
      await pumpPage(tester, '/video/api/play/b/2');
      await pumpUntil(tester, playing, reason: '再次打开开始播放');
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        expect(subtitleText(tester), '', reason: '记录为关闭');
      }
      await tester.pumpWidget(const SizedBox());
    });
  });
}
