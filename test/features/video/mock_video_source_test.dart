import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/network/dio_source_http_client.dart';
import 'package:tsumugi/core/network/media/media_proxy.dart';
import 'package:tsumugi/core/network/source_http_client.dart';
import 'package:tsumugi/core/storage/app_database.dart';
import 'package:tsumugi/sources/model/content.dart';
import 'package:tsumugi/sources/network_error_mapping.dart';
import 'package:tsumugi/sources/registry/providers.dart';
import 'package:tsumugi/sources/runtime/source_runtime.dart';

import '../../core/network/mock_support.dart';
import '../../core/storage/test_database.dart';
import '../../sources/runtime/runtime_support.dart';

const _id = 'com.example.mock.video.declarative';

/// 虚构视频源（test/fixtures/sources/mock_video_declarative.json）走完整流程：
/// 搜索 → 详情 → content → 本地媒体代理（使用清单生成的网络配置，含默认 Referer）。
void main() {
  late AppDatabase db;
  late MockServer server;
  late ProviderContainer container;

  setUp(() async {
    db = openTestDatabase();
    server = await MockServer.start();
    final registry = SourceRegistry(db);
    await registry.importText(
      File('test/fixtures/sources/mock_video_declarative.json')
          .readAsStringSync(),
    );
    container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        sourceFactoriesProvider.overrideWithValue(mockFactories(server)),
      ],
    );
  });
  tearDown(() async {
    container.dispose();
    await server.close();
    await db.close();
  });

  test('搜索、详情与剧集的流', () async {
    final source = await container.read(sourceInstanceProvider(_id).future);
    final found = await source.search('彩条', 1);
    expect(found.items.single.id, '/video/show/1');

    final detail = await source.detail('/video/show/1');
    expect(detail.title, '测试彩条');
    expect(detail.units.map((u) => u.id), [
      for (var i = 1; i <= 4; i++) '/video/show/1/ep/$i',
    ]);

    final ep2 = await source.content('/video/show/1/ep/2') as VideoContent;
    final stream = ep2.streams.single;
    expect(stream.type, StreamType.hls);
    expect(stream.url, 'http://127.0.0.1:8080/video/media/hls/master.m3u8');
    expect(stream.headers, {'Referer': 'http://127.0.0.1:8080/video/'});
  });

  test('需要 Referer 与 Cookie 的剧集：代理经源取得密钥并解密分片', () async {
    final source = await container.read(sourceInstanceProvider(_id).future);
    await source.detail('/video/show/1'); // 源实例的请求不影响下面独立的客户端
    final ep4 = await source.content('/video/show/1/ep/4') as VideoContent;
    final stream = ep4.streams.single;

    final manifest = (await container.read(sourceRegistryProvider).get(_id))!
        .manifest!;
    final client = DioSourceHttpClient(
      networkConfigFromManifest(manifest),
      adapter: mockAdapter(server),
    );
    final proxy = await MediaProxy.start();
    final player = HttpClient();
    addTearDown(() async {
      player.close(force: true);
      await proxy.close();
      client.close();
    });

    Future<(int, String)> get(Uri url) async {
      final res = await (await player.getUrl(url)).close();
      return (res.statusCode, await utf8.decoder.bind(res).join());
    }

    // 与播放页相同：会话的 Cookie 来自之前经源访问的详情页。
    await client.request(const NetRequest('/video/show/1'));
    final session = proxy.open(
      client: client,
      url: Uri.parse(stream.url),
      headers: stream.headers ?? const {},
    );
    final (s1, master) = await get(session.url);
    expect(s1, 200);
    final variant = Uri.parse(
      const LineSplitter().convert(master).lastWhere((l) => l.isNotEmpty),
    );
    final (s2, media) = await get(variant);
    expect(s2, 200);
    final seg = Uri.parse(
      const LineSplitter().convert(media).firstWhere((l) => !l.startsWith('#')),
    );
    final res = await (await player.getUrl(seg)).close();
    expect(res.statusCode, 200);
    final plain = await res.fold<List<int>>([], (a, c) => a..addAll(c));
    expect(plain.first, 0x47, reason: '代理解密后为 MPEG-TS');
    expect(
      server.requests
          .where((r) => r.path.startsWith('/video/protected/'))
          .map((r) => r.headers['referer'])
          .toSet(),
      {'http://127.0.0.1:8080/video/'},
    );
  });
}
