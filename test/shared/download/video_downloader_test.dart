import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/network/media/aes128.dart';
import 'package:tsumugi/core/network/source_http_client.dart';
import 'package:tsumugi/shared/download/video_downloader.dart';
import 'package:tsumugi/shared/download/video_manifest.dart';
import 'package:tsumugi/sources/model/content.dart';
import 'package:tsumugi/sources/source.dart';

import '../../core/network/mock_support.dart';

/// 视频下载（architecture §4.5.1）：经 mock 服务器的 HLS（明文 / AES-128 / 字幕轨 / 直播 / SAMPLE-AES）
/// 与单文件（有 / 无 ETag）。
void main() {
  late MockServer server;
  late Directory dir;
  late SourceHttpClient client;

  setUpAll(() async => server = await MockServer.start());
  tearDownAll(() => server.close());

  setUp(() async {
    server.requests.clear();
    server.videoRevision = 0;
    dir = await Directory.systemTemp.createTemp('tsumugi_video_');
    client = mockClient(
      server,
      sourceId: 'com.example.video',
      baseUrl: 'http://video.example.com',
      allowedHosts: const [],
    );
  });

  tearDown(() async {
    client.close();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Uint8List fixture(String name) =>
      File('test/fixtures/mock_site/video/$name').readAsBytesSync();

  Uint8List plain(int i) {
    final iv = Uint8List(16)..[15] = 1;
    return decryptHlsAes128(
      fixture('hls/seg$i.ts'),
      fixture('hls/key.bin'),
      iv,
    );
  }

  Future<(int, int, int)> run(
    VideoContent content, {
    String? label,
    VideoDownloadLimits limits = const VideoDownloadLimits(
      progressInterval: Duration.zero,
    ),
    NetCancellation? abort,
    List<(int, int, int)>? progress,
  }) => VideoDownloadTask(
    client: client,
    baseUrl: Uri.parse('http://video.example.com'),
    content: content,
    preferredLabel: label,
    dir: dir,
    abort: abort ?? NetCancellation(),
    limits: limits,
    onProgress: (c, t, b) async => progress?.add((c, t, b)),
  ).run();

  VideoManifest manifest() => VideoManifest.decode(
    File('${dir.path}/$videoManifestFileName').readAsStringSync(),
  );

  File file(String name) => File('${dir.path}/$name');

  Matcher throwsCode(SourceErrorCode code) =>
      throwsA(isA<SourceException>().having((e) => e.code, 'code', code));

  VideoContent hls(String path, {List<SubtitleRef> subtitles = const []}) =>
      VideoContent(
        streams: [
          StreamRef(
            url: '/video/media/hls/$path',
            type: StreamType.hls,
            quality: '720p',
          ),
          const StreamRef(
            url: '/video/media/clip.mp4',
            type: StreamType.mp4,
            quality: '360p',
          ),
        ],
        subtitles: subtitles,
      );

  group('HLS', () {
    test('AES-128 segments are stored decrypted; subtitle track and external subtitles', () async {
      final progress = <(int, int, int)>[];
      final result = await run(
        hls(
          'master_sub.m3u8',
          subtitles: const [
            SubtitleRef(
              url: '/video/media/subs/zh.srt',
              lang: '简体中文',
              format: 'srt',
            ),
            SubtitleRef(
              url: '/video/media/subs/bad.srt',
              lang: '损坏示例',
              format: 'srt',
            ),
            SubtitleRef(url: '/video/media/subs/missing.srt', lang: '不存在'),
            SubtitleRef(url: '/video/media/subs/ja.ass', lang: '日本語'),
          ],
        ),
        progress: progress,
      );
      expect(result.$1, 6);
      expect(result.$2, 6);
      final m = manifest();
      expect(m.label, '720p');
      expect(m.complete, isTrue);
      expect(m.tracks.map((t) => t.dir), ['v', 's1']);
      expect(m.tracks[1].name, 'HLS Chinese');
      for (var i = 0; i < 3; i++) {
        expect(file('v/0000${i + 1}.ts').readAsBytesSync(), plain(i));
        expect(
          file('s1/0000${i + 1}.vtt').readAsBytesSync(),
          fixture('hls/sub$i.vtt'),
        );
      }
      // 伪装成字幕的 HTML 与 404 的字幕跳过；其余按原样保存，序号与 content.subtitles 对应。
      expect(
        [for (final s in m.subtitles) s.file],
        ['sub-01.srt', 'sub-04.ass'],
      );
      expect(file('sub-01.srt').readAsBytesSync(), fixture('subs/zh.srt'));
      // 不保存密钥、播放列表原文与上游地址。
      final names = [
        for (final e in dir.listSync(recursive: true))
          e.path.substring(dir.path.length + 1).replaceAll(r'\', '/'),
      ];
      expect(
        names.where((n) => n.contains('key') || n.endsWith('.m3u8')),
        isEmpty,
      );
      expect(
        file(videoManifestFileName).readAsStringSync(),
        isNot(contains('example.com')),
      );
      expect(progress.last.$1, 6);
      // 分片与密钥走媒体配额，带 identity 编码。
      final segs = server.requests.where((r) => r.path.endsWith('.ts'));
      expect(segs, hasLength(3));
      expect(
        segs.every((r) => r.headers['accept-encoding'] == 'identity'),
        isTrue,
      );
      expect(server.hits('/video/media/hls/key.bin'), 1);
    });

    test(
      'master with two variants picks the higher bandwidth (plain)',
      () async {
        await run(hls('master_plain.m3u8'));
        expect(server.hits('/video/media/hls/plain.m3u8'), 1);
        expect(server.hits('/video/media/hls/index.m3u8'), 0);
        expect(server.hits('/video/media/hls/key.bin'), 0);
        expect(file('v/00002.ts').readAsBytesSync(), plain(1));
        expect(manifest().bandwidth, 148896);
      },
    );

    test('live playlists and SAMPLE-AES fail with E_UNSUPPORTED', () async {
      await expectLater(
        run(hls('live.m3u8')),
        throwsCode(SourceErrorCode.unsupported),
      );
      await expectLater(
        run(hls('sample_aes.m3u8')),
        throwsCode(SourceErrorCode.unsupported),
      );
      expect(server.requests.where((r) => r.path.endsWith('.ts')), isEmpty);
    });

    test('segment count limit → E_LIMIT before any segment request', () async {
      await expectLater(
        run(
          hls('master_sub.m3u8'),
          limits: const VideoDownloadLimits(maxItems: 5),
        ),
        throwsCode(SourceErrorCode.limit),
      );
      expect(server.requests.where((r) => r.path.endsWith('.ts')), isEmpty);
    });

    test(
      'byte limit counts actual bytes and deletes what was written',
      () async {
        await expectLater(
          run(
            hls('plain.m3u8'),
            limits: const VideoDownloadLimits(maxBytes: 40000),
          ),
          throwsCode(SourceErrorCode.limit),
        );
        expect(dir.existsSync() && dir.listSync().isNotEmpty, isFalse);
      },
    );

    test('resume skips written segments when the source key matches', () async {
      await run(hls('plain.m3u8'));
      // 模拟中断：删掉第 2 个分片的记录与文件。
      final m = manifest();
      final items = List.of(m.tracks.first.items);
      items[1] = items[1].withFile(null);
      file('v/00002.ts').deleteSync();
      file(videoManifestFileName).writeAsStringSync(
        m.copyWith(tracks: [m.tracks.first.withItems(items)]).encode(),
      );
      server.requests.clear();
      await run(hls('plain.m3u8'));
      expect(
        [for (final r in server.requests) r.path]
            .where((p) => p.endsWith('.ts')),
        ['/video/media/hls/plain/seg1.ts'],
      );
      expect(manifest().complete, isTrue);
    });

    test('a changed source key discards earlier files', () async {
      await run(hls('plain.m3u8'));
      final m = manifest();
      file(videoManifestFileName).writeAsStringSync(
        VideoManifest.hls(
          sourceKey: 'b' * 64,
          label: m.label,
          tracks: m.tracks,
        ).encode(),
      );
      final marker = file('v/00009.ts')..writeAsStringSync('stale');
      server.requests.clear();
      await run(hls('plain.m3u8'));
      expect(
        server.requests.where((r) => r.path.endsWith('.ts')),
        hasLength(3),
      );
      expect(marker.existsSync(), isFalse);
    });

    test('cancel aborts in-flight requests', () async {
      final abort = NetCancellation()..cancel();
      await expectLater(
        run(hls('plain.m3u8'), abort: abort),
        throwsA(anything),
      );
    });
  });

  group('single file', () {
    VideoContent mp4(String path) => VideoContent(
      streams: [StreamRef(url: path, type: StreamType.mp4, quality: '360p')],
    );

    test('whole file with validators recorded', () async {
      await run(mp4('/video/media/clip.mp4'));
      expect(file(videoFileName).readAsBytesSync(), fixture('clip.mp4'));
      final m = manifest();
      expect(m.isHls, isFalse);
      expect(m.file?.length, fixture('clip.mp4').length);
      expect(m.file?.etag, isNotNull);
    });

    test('resumes with Range + If-Range when a strong ETag is known', () async {
      await run(mp4('/video/media/clip.mp4'));
      final full = fixture('clip.mp4');
      // 模拟中断：只留前 1000 字节。
      file(videoFileName).writeAsBytesSync(full.sublist(0, 1000));
      server.requests.clear();
      await run(mp4('/video/media/clip.mp4'));
      final req = server.requests.single;
      expect(req.headers['range'], 'bytes=1000-');
      expect(req.headers['if-range'], manifest().file!.etag);
      expect(file(videoFileName).readAsBytesSync(), full);
    });

    test('content changed upstream (If-Range mismatch → 200) restarts from scratch', () async {
      await run(mp4('/video/media/clip.mp4'));
      file(videoFileName)
          .writeAsBytesSync(fixture('clip.mp4').sublist(0, 1000));
      server.videoRevision = 1;
      server.requests.clear();
      await run(mp4('/video/media/clip.mp4'));
      expect(server.requests, hasLength(1));
      final expected = [...fixture('clip.mp4'), 1];
      expect(file(videoFileName).readAsBytesSync(), expected);
    });

    test('already complete file (marker missing) is confirmed with 1 byte, not re-downloaded', () async {
      const content = VideoContent(
        streams: [StreamRef(url: '/video/media/clip.mp4', quality: '360p')],
        subtitles: [SubtitleRef(url: '/video/media/subs/zh.srt', lang: 'zh')],
      );
      await run(content);
      server.requests.clear();
      await run(content);
      final len = fixture('clip.mp4').length;
      expect(
        [for (final r in server.requests) r.headers['range']],
        ['bytes=${len - 1}-'],
      );
      expect(file(videoFileName).readAsBytesSync(), fixture('clip.mp4'));
      expect(manifest().subtitles.single.file, 'sub-01.srt');
    });

    test(
      'external subtitles are kept on resume only when the URL is unchanged',
      () async {
        VideoContent withSub(String path) => VideoContent(
          streams: const [
            StreamRef(url: '/video/media/clip.mp4', quality: '360p'),
          ],
          subtitles: [SubtitleRef(url: path, lang: 'zh')],
        );
        await run(withSub('/video/media/subs/zh.srt'));
        server.requests.clear();
        await run(withSub('/video/media/subs/zh.srt'));
        expect(server.hits('/video/media/subs/zh.srt'), 0);
        await run(withSub('/video/media/subs/en.vtt'));
        expect(server.hits('/video/media/subs/en.vtt'), 1);
        expect(manifest().subtitles.single.file, 'sub-01.vtt');
      },
    );

    test(
      'no validators → no range request, downloads from the start',
      () async {
        await run(mp4('/video/noetag/clip.mp4'));
        expect(manifest().file?.validator, isNull);
        file(videoFileName)
            .writeAsBytesSync(fixture('clip.mp4').sublist(0, 1000));
        server.requests.clear();
        await run(mp4('/video/noetag/clip.mp4'));
        expect(server.requests.single.headers['range'], isNull);
        expect(file(videoFileName).readAsBytesSync(), fixture('clip.mp4'));
      },
    );

    test('declared length over the limit → E_LIMIT without writing', () async {
      await expectLater(
        run(
          mp4('/video/media/clip.mp4'),
          limits: const VideoDownloadLimits(maxBytes: 1000),
        ),
        throwsCode(SourceErrorCode.limit),
      );
      expect(file(videoFileName).existsSync(), isFalse);
    });

    test('external subtitles count against the byte limit', () async {
      final len = fixture('clip.mp4').length;
      await expectLater(
        run(
          const VideoContent(
            streams: [StreamRef(url: '/video/noetag/clip.mp4')],
            subtitles: [SubtitleRef(url: '/video/media/subs/ja.ass')],
          ),
          limits: VideoDownloadLimits(maxBytes: len + 10),
        ),
        throwsCode(SourceErrorCode.limit),
      );
      expect(file(videoFileName).existsSync(), isFalse);
    });

    test('non-media content is rejected', () async {
      await expectLater(
        run(mp4('/video/media/subs/zh.srt')),
        throwsCode(SourceErrorCode.parse),
      );
    });

    test('picks the stream with the chosen label, else the first', () async {
      final content = hls('plain.m3u8');
      await run(content, label: '360p');
      expect(manifest().isHls, isFalse);
      expect(manifest().label, '360p');
      await dir.delete(recursive: true);
      await run(content, label: '1080p');
      expect(manifest().label, '720p');
    });
  });
}
