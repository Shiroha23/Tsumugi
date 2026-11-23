// M6 第二期：视频下载与离线回放（docs/architecture.md §4.5.1）。完整应用（真实路由、脚本引擎、下载队列、
// 媒体代理与磁盘文件）：
//
// 1. 视频详情页「下载」：选择剧集与清晰度（720p：带 HLS 字幕轨的 AES-128 HLS + 外挂字幕）；
// 2. mock 服务器断网（之后的连接都被直接断开）；
// 3. 本地来源会话：主播放列表、分片（已是明文）、字幕轨经代理按编号返回；外挂字幕从本地文件解析；
// 4. 播放页离线播放并选字幕（只在 Windows 上：x86_64 模拟器没有视频输出，见 §5.4）。
//
// 运行方式同 download_offline_test.dart：
//
//   Windows：flutter test integration_test/video_download_offline_test.dart -d windows
//
//   Android / iOS 模拟器（先在电脑上以 --test-control 启动 mock 服务器）：
//     dart run tool/mock_server/main.dart --port 8081 --test-control
//     adb reverse tcp:8081 tcp:8081          # 仅 Android
//     flutter test integration_test/video_download_offline_test.dart -d <设备> \
//       --dart-define=TSUMUGI_MOCK_SERVER=127.0.0.1:8081

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tsumugi/app/router.dart';
import 'package:tsumugi/core/network/dio_source_http_client.dart';
import 'package:tsumugi/core/storage/app_database.dart';
import 'package:tsumugi/features/explore/explore_preferences.dart';
import 'package:tsumugi/features/video/video_routes.dart';
import 'package:tsumugi/shared/download/providers.dart';
import 'package:tsumugi/shared/video/media_proxy_providers.dart';
import 'package:tsumugi/shared/video/subtitle_providers.dart';
import 'package:tsumugi/sources/network_error_mapping.dart';
import 'package:tsumugi/sources/registry/providers.dart';
import 'package:tsumugi/sources/session/source_sessions.dart';

import '../test/core/storage/test_database.dart';
import '../test/sources/runtime/runtime_support.dart';
import 'test_mock.dart';

const _sourceId = 'com.example.mock.video.script';
const _itemId = '/video/api/show/2';
const _ep1 = '/video/api/play/a/1';

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() done, {
  Duration timeout = const Duration(seconds: 60),
  String? reason,
}) async {
  final end = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(end)) fail('超时：${reason ?? ''}');
    await tester.pump(const Duration(milliseconds: 100));
  }
}

bool _found(Finder f) => f.evaluate().isNotEmpty;

/// 播放器一侧：直接用 dart:io 访问代理（代理只监听本机回环地址，设备上同样可用）。
Future<(int, List<int>)> _get(Uri url) async {
  final http = HttpClient();
  try {
    final res = await (await http.getUrl(url)).close();
    final body = await res.fold<List<int>>([], (b, c) => b..addAll(c));
    return (res.statusCode, body);
  } finally {
    http.close(force: true);
  }
}

List<Uri> _uris(String playlist) => [
  for (final line in const LineSplitter().convert(playlist))
    if (line.isNotEmpty && !line.startsWith('#'))
      Uri.parse(line)
    else
      for (final m in RegExp(r'URI="([^"]*)"').allMatches(line))
        Uri.parse(m[1]!),
];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  late TestMock server;
  late Directory downloads;

  setUp(() async {
    server = await TestMock.start();
    downloads = await (await getTemporaryDirectory()).createTemp(
      'tsumugi_vdl_',
    );
  });
  tearDown(() async {
    await server.close();
    await downloads.delete(recursive: true);
  });

  testWidgets('下载一集（720p HLS + 字幕）→ 断网 → 本地会话离线播放并选字幕', (tester) async {
    final db = openTestDatabase();
    final subtitlePrefs = MemorySubtitlePreferencesStore();
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        sessionPersistenceProvider.overrideWithValue(null),
        subtitlePreferencesStoreProvider.overrideWithValue(subtitlePrefs),
        explorePreferencesStoreProvider.overrideWithValue(
          MemoryExplorePreferencesStore(),
        ),
        sourceFactoriesProvider.overrideWith(
          (ref) => adapterFactories(
            server.adapter,
            session: ref.read(sourceSessionsProvider).of,
          ),
        ),
        // 下载与在线播放用同一个客户端工厂（该源的 SourceSession：线路 A 的密钥要求详情页种下的 vtoken）。
        mediaProxyClientProvider.overrideWith(
          (ref) =>
              (manifest) => DioSourceHttpClient(
                networkConfigFromManifest(manifest),
                adapter: server.adapter(),
                session: ref.read(sourceSessionsProvider).of(manifest.id),
              ),
        ),
        downloadStoreProvider.overrideWithValue(DownloadStore(() => downloads)),
      ],
    );
    await tester.runAsync(
      () async => SourceRegistry(db)
          .importText(await server.fixture('sources/mock_video_script.json')),
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: Consumer(
          builder: (context, ref, _) {
            ref.watch(downloadManagerProvider);
            return MaterialApp.router(routerConfig: ref.watch(routerProvider));
          },
        ),
      ),
    );
    await tester.pump();
    final router = container.read(routerProvider);

    // 1. 详情页「下载」：线路 A 第 1 集，清晰度默认第一个（720p）。
    router.push(VideoRoutes.detail(_sourceId, _itemId));
    await _pumpUntil(tester, () => _found(find.text('第 1 集')), reason: '详情');
    final downloadButton = find.widgetWithText(OutlinedButton, '下载');
    await tester.ensureVisible(downloadButton);
    await tester.tap(downloadButton);
    await _pumpUntil(
      tester,
      () => _found(find.byKey(const ValueKey('download-quality'))),
      reason: '清晰度列表',
    );
    expect(find.text('720p'), findsOneWidget);
    await tester.tap(find.text('起止剧集'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('download-range-到')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1. 第 1 集').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始下载'));
    await _pumpUntil(
      tester,
      () => _found(find.text('已加入下载队列（1 集）')),
      reason: '加入队列',
    );
    final repo = container.read(downloadRepositoryProvider);
    final end = DateTime.now().add(const Duration(seconds: 90));
    while (true) {
      final u = (await tester.runAsync(
        () => repo.unit(_sourceId, _itemId, _ep1),
      ));
      if (u?.status == DownloadStatus.failed) fail('下载失败：${u?.errorCode}');
      if (u?.status == DownloadStatus.done) break;
      if (DateTime.now().isAfter(end)) fail('下载超时：${u?.status}');
      await tester.pump(const Duration(milliseconds: 200));
    }
    final before = (await tester.runAsync(server.requests))!;
    expect(
      before.map((r) => r.path),
      containsAll([
        '/video/protected/hls/key.bin',
        '/video/protected/hls/seg0.ts',
        '/video/protected/hls/sub0.vtt',
        '/video/protected/subs/zh.srt',
      ]),
    );

    // 2. 断网。
    await tester.runAsync(server.goOffline);

    // 3. 本地来源会话：播放器能取到的只有代理地址，分片已是明文 MPEG-TS。
    final library = container.read(downloadLibraryProvider);
    final video = (await tester.runAsync(
      () => library.video(_sourceId, _itemId, _ep1),
    ))!;
    expect(video.label, '720p');
    expect(video.manifest.tracks.map((t) => t.dir), ['v', 's1']);
    // 外挂字幕：伪装成字幕的 HTML 被跳过，其余 4 条按原样保存。
    expect(video.subtitles.map((s) => s.$1.lang), [
      '简体中文',
      '简体中文（GBK）',
      'English',
      '日本語',
    ]);
    final gbk = (await tester.runAsync(
      () =>
          loadDownloadedSubtitle(video.subtitles[1].$2, video.subtitles[1].$1),
    ))!;
    expect(gbk.cues.first.text, startsWith('GBK 字幕：'));
    await tester.runAsync(() async {
      final stream = await container.read(openLocalVideoProvider)(video);
      try {
        final (status, master) = await _get(stream.url);
        expect(status, 200);
        final masterText = utf8.decode(master);
        // 字幕轨不交给播放器（#84）：记在本地会话上，字幕层经本会话取本地分片。
        expect(masterText, isNot(contains('TYPE=SUBTITLES')));
        final [variant] = _uris(masterText);
        final track = stream.subtitleTracks.single;
        expect((track.name, track.language), ('HLS Chinese', 'zh'));
        final sub = utf8.decode((await _get(Uri.parse(track.url))).$2);
        final (vttStatus, vtt) = await _get(_uris(sub).first);
        expect(vttStatus, 200);
        expect(utf8.decode(vtt), startsWith('WEBVTT'));
        final doc = await loadStreamSubtitleTrack(
          track,
          presentationStart: const Duration(milliseconds: 1400),
        );
        expect(doc.cues.map((c) => (c.start, c.text)), [
          (Duration.zero, 'HLS subtitle 1'),
          (const Duration(seconds: 2), 'HLS subtitle 2'),
          (const Duration(seconds: 4), 'HLS subtitle 3'),
        ]);
        final media = utf8.decode((await _get(variant)).$2);
        expect(media, isNot(contains('EXT-X-KEY')));
        final seg = _uris(media).first;
        expect(seg.host, '127.0.0.1');
        final (segStatus, segBody) = await _get(seg);
        expect(segStatus, 200);
        expect(segBody.first, 0x47, reason: 'MPEG-TS 明文');
        expect(stream.localFileError, isFalse);
      } finally {
        stream.close();
      }
    });

    // 4. 播放页：已下载的剧集不调用 content()，经本地会话播放；清晰度只有 720p。
    // 真实播放只在 Windows 上：x86_64 Android 模拟器没有视频输出（§5.4），iOS 模拟器未验证 libmpv 播放。
    final canPlayVideo = Platform.isWindows;
    if (canPlayVideo) {
      // 记住的字幕为 HLS 字幕轨的语言（zh）：打开时按语言匹配自动选上。字幕层经本地会话取本地字幕分片（#84）。
      subtitlePrefs.values[_sourceId] = const SubtitleLabel('zh');
      router.push(VideoRoutes.player(_sourceId, _itemId, _ep1));
      bool playing() =>
          find.byType(CircularProgressIndicator).evaluate().isEmpty &&
          _found(find.byTooltip('字幕'));
      await _pumpUntil(tester, playing, reason: '离线开始播放');
      expect(find.textContaining('出错'), findsNothing);
      expect(find.byTooltip('清晰度'), findsNothing, reason: '只有一个清晰度');
      Future<void> choose(String label) async {
        await tester.tap(find.byTooltip('字幕'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(label).last);
        await tester.pump();
      }

      // HLS 字幕轨来自本地播放列表：菜单中有它（标签为 NAME），按记住的选择选中，文字照常显示。
      String subtitleText() {
        final f = find.byKey(const ValueKey('video-subtitle-text'));
        return f.evaluate().isEmpty ? '' : tester.widget<Text>(f).data ?? '';
      }

      await _pumpUntil(
        tester,
        () => const {
          'HLS subtitle 1',
          'HLS subtitle 2',
          'HLS subtitle 3',
        }.contains(subtitleText()),
        reason: '离线显示 HLS 字幕轨',
      );
      await tester.tap(find.byTooltip('字幕'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CheckedPopupMenuItem<Object?>>(
              find.ancestor(
                of: find.text('HLS Chinese（内嵌）'),
                matching: find.byWidgetPredicate(
                  (w) => w is CheckedPopupMenuItem,
                ),
              ),
            )
            .checked,
        isTrue,
      );
      await tester.tapAt(const Offset(5, 5)); // 关闭菜单
      await tester.pumpAndSettle();
      // 外挂字幕（本地文件解析）：取得成功后才按源记住。
      await choose('English');
      await _pumpUntil(
        tester,
        () => subtitlePrefs.values[_sourceId] == const SubtitleLabel('English'),
        reason: '本地外挂字幕',
      );
      expect(find.textContaining('加载失败'), findsNothing);
    }

    // 断网后没有任何请求到达服务器。
    final after = (await tester.runAsync(server.requests))!;
    expect(after.length, before.length);

    // 下载目录中只有哈希与序号构成的路径。
    final names = (await tester.runAsync(
      () => downloads.list(recursive: true).map((e) => e.path).toList(),
    ))!;
    for (final p in names) {
      final rel = p.substring(downloads.path.length + 1).replaceAll(r'\', '/');
      expect(
        rel,
        matches(
          RegExp(
            r'^[0-9a-f]{32}(/[0-9a-f]{32}){0,2}'
            r'(/(video\.json|\.done|sub-\d{2}\.(srt|vtt|ass)|v|s1|v/\d{5}\.ts|s1/\d{5}\.vtt))?$',
          ),
        ),
      );
    }

    await tester.pumpWidget(const SizedBox());
    container.dispose();
    await tester.pump(const Duration(milliseconds: 100));
    await db.close();
  });
}
