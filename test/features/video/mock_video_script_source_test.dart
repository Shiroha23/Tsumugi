import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/storage/app_database.dart';
import 'package:tsumugi/features/video/player/video_playlist.dart';
import 'package:tsumugi/sources/model/content.dart';
import 'package:tsumugi/sources/registry/providers.dart';
import 'package:tsumugi/sources/runtime/source_runtime.dart';

import '../../core/network/mock_support.dart';
import '../../core/storage/test_database.dart';
import '../../sources/runtime/runtime_support.dart';

const _id = 'com.example.mock.video.script';
const _manifest = 'test/fixtures/sources/mock_video_script.json';

/// 多线路 / 多清晰度的虚构脚本源（mock 服务器 `/video/api/*`）。
void main() {
  test('清单内联的脚本与 test/fixtures/script/video/source.js 一致', () {
    final json =
        jsonDecode(File(_manifest).readAsStringSync()) as Map<String, Object?>;
    expect(
      json['script'],
      File('test/fixtures/script/video/source.js').readAsStringSync(),
    );
  });

  group('经 mock 服务器', () {
    late AppDatabase db;
    late MockServer server;
    late ProviderContainer container;

    setUp(() async {
      db = openTestDatabase();
      server = await MockServer.start();
      await SourceRegistry(db).importText(File(_manifest).readAsStringSync());
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

    test('搜索 → 两条线路的详情 → 每集两个清晰度', () async {
      final source = await container.read(sourceInstanceProvider(_id).future);
      final found = await source.search('彩条', 1);
      expect(found.items.single.id, '/video/api/show/2');

      final detail = await source.detail('/video/api/show/2');
      final playlist = VideoPlaylist(detail);
      expect(playlist.lines.map((l) => l.name), ['线路 A', '线路 B']);
      expect(playlist.lines[1].units.map((u) => u.id), [
        for (var i = 1; i <= 3; i++) '/video/api/play/b/$i',
      ]);
      // 切换线路：同一集。
      final at = playlist.locate('/video/api/play/a/2')!;
      expect(
        playlist.unitAt(playlist.switchLine(at, 1)!)!.id,
        '/video/api/play/b/2',
      );

      final content =
          await source.content('/video/api/play/a/2') as VideoContent;
      final streams = playableStreams(content);
      expect(
        [for (var i = 0; i < 2; i++) streamLabel(streams, i)],
        ['720p', '360p'],
      );
      expect(streams.first.type, StreamType.hls);
      expect(
        streams.first.url,
        'http://127.0.0.1:8080/video/protected/hls/master.m3u8',
      );
      expect(streams.last.type, StreamType.mp4);
    });
  });
}
