import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:tsumugi/core/network/dio_source_http_client.dart';
import 'package:tsumugi/core/network/network_exception.dart';
import 'package:tsumugi/core/network/source_http_client.dart';
import 'package:tsumugi/shared/download/video_downloader.dart';
import 'package:tsumugi/shared/download/video_manifest.dart';
import 'package:tsumugi/sources/model/content.dart';
import 'package:tsumugi/sources/source.dart';

/// 视频下载的反向用例（本地审查意见 6）：用测试内构造的上游覆盖 mock 服务器没有的情形。
/// 任意主机名的连接都接到这里，白名单仍按主机名检查（只允许 `video.example.com`）。
void main() {
  late HttpServer upstream;
  final routes = <String, Future<void> Function(HttpRequest req)>{};
  final hits = <String>[];
  late Directory dir;
  late DioSourceHttpClient client;

  setUpAll(() async {
    upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    upstream.listen((req) async {
      hits.add('${req.headers.host}${req.uri.path}');
      final h = routes[req.uri.path];
      if (h == null) {
        req.response.statusCode = 404;
        return req.response.close();
      }
      try {
        await h(req);
      } on Object {
        // 客户端已断开（超时 / 取消用例）：写入失败不影响其他用例。
      }
    });
  });
  tearDownAll(() => upstream.close(force: true));

  setUp(() async {
    routes.clear();
    hits.clear();
    dir = await Directory.systemTemp.createTemp('tsumugi_vdlb_');
    client = DioSourceHttpClient(
      SourceNetworkConfig(
        sourceId: 'com.example.video',
        baseUrl: Uri.parse('http://video.example.com'),
        timeout: const Duration(seconds: 5),
        retryBaseDelay: const Duration(milliseconds: 10),
        maxRetries: 0,
      ),
      adapter: IOHttpClientAdapter(
        createHttpClient: () => HttpClient()
          ..connectionFactory = (uri, proxyHost, proxyPort) =>
              Socket.startConnect(InternetAddress.loopbackIPv4, upstream.port),
      ),
    );
  });
  tearDown(() async {
    client.close();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  void text(
    String path,
    String body, {
    String type = 'application/vnd.apple.mpegurl',
  }) => routes[path] = (req) {
    req.response.headers.set('content-type', type);
    req.response.add(utf8.encode(body));
    return req.response.close();
  };

  void bytes(
    String path,
    List<int> body, {
    int status = 200,
    Map<String, String> headers = const {},
  }) => routes[path] = (req) {
    req.response.statusCode = status;
    headers.forEach(req.response.headers.set);
    req.response.add(body);
    return req.response.close();
  };

  /// MPEG-TS 同步字节开头的假分片。
  Uint8List ts([int n = 1880]) => Uint8List.fromList([
    for (var i = 0; i < n; i++) i % 188 == 0 ? 0x47 : (i % 7) + 1,
  ]);

  Uint8List encrypt(Uint8List plain, Uint8List key, Uint8List iv) {
    final c = PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))
      ..init(
        true,
        PaddedBlockCipherParameters(
          ParametersWithIV(KeyParameter(key), iv),
          null,
        ),
      );
    return c.process(plain);
  }

  Future<(int, int, int)> run({
    String url = '/index.m3u8',
    StreamType type = StreamType.hls,
    VideoDownloadLimits limits = const VideoDownloadLimits(
      progressInterval: Duration.zero,
    ),
    NetCancellation? abort,
    Map<String, String>? headers,
  }) => VideoDownloadTask(
    client: client,
    baseUrl: Uri.parse('http://video.example.com'),
    content: VideoContent(
      streams: [StreamRef(url: url, type: type, headers: headers)],
    ),
    preferredLabel: null,
    dir: dir,
    abort: abort ?? NetCancellation(),
    limits: limits,
    onProgress: (_, _, _) async {},
  ).run();

  String media(List<String> segs, {String extra = ''}) =>
      '#EXTM3U\n#EXT-X-TARGETDURATION:2\n$extra'
      '${[for (final s in segs) '#EXTINF:2,\n$s'].join('\n')}\n#EXT-X-ENDLIST\n';

  Matcher code(SourceErrorCode c) =>
      throwsA(isA<SourceException>().having((e) => e.code, 'code', c));
  Matcher net(NetworkErrorKind k) =>
      throwsA(isA<NetworkException>().having((e) => e.kind, 'kind', k));

  List<String> written() => [
    for (final e in dir.listSync(recursive: true))
      if (e is File && e.path.endsWith('.ts')) e.path,
  ];

  test('segment on a host outside the whitelist', () async {
    text('/index.m3u8', media(['/a.ts', 'http://outside.example.net/b.ts']));
    bytes('/a.ts', ts());
    await expectLater(run(), net(NetworkErrorKind.hostNotAllowed));
    expect(hits.where((h) => h.startsWith('outside')), isEmpty);
  });

  test('segment redirecting outside the whitelist', () async {
    text('/index.m3u8', media(['/r.ts']));
    routes['/r.ts'] = (req) {
      req.response
        ..statusCode = 302
        ..headers.set('location', 'http://outside.example.net/x.ts');
      return req.response.close();
    };
    await expectLater(run(), net(NetworkErrorKind.hostNotAllowed));
    expect(hits.where((h) => h.startsWith('outside')), isEmpty);
    expect(written(), isEmpty);
  });

  test('variant and subtitle playlists outside the whitelist', () async {
    text(
      '/index.m3u8',
      '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nhttp://outside.example.net/v.m3u8\n',
    );
    await expectLater(run(), net(NetworkErrorKind.hostNotAllowed));
    text(
      '/index.m3u8',
      '#EXTM3U\n'
          '#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="s",NAME="x",URI="http://outside.example.net/s.m3u8"\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=1,SUBTITLES="s"\n/v.m3u8\n',
    );
    text('/v.m3u8', media(['/a.ts']));
    await expectLater(run(), net(NetworkErrorKind.hostNotAllowed));
    expect(hits.where((h) => h.startsWith('outside')), isEmpty);
  });

  test('key outside the whitelist', () async {
    text(
      '/index.m3u8',
      media(
        ['/a.ts'],
        extra: '#EXT-X-KEY:METHOD=AES-128,URI="http://outside.example.net/k"\n',
      ),
    );
    bytes('/a.ts', List.filled(32, 1));
    await expectLater(run(), net(NetworkErrorKind.hostNotAllowed));
  });

  test('HTML or text disguised as a segment is rejected', () async {
    text('/index.m3u8', media(['/a.ts']));
    text(
      '/a.ts',
      '<html><body>not a video</body></html>' * 50,
      type: 'video/mp2t',
    );
    await expectLater(run(), code(SourceErrorCode.parse));
    expect(written(), isEmpty);
  });

  test('subtitle track segments must be WebVTT', () async {
    text(
      '/index.m3u8',
      '#EXTM3U\n'
          '#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="s",NAME="x",URI="/s.m3u8"\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=1,SUBTITLES="s"\n/v.m3u8\n',
    );
    text('/v.m3u8', media(['/a.ts']));
    text('/s.m3u8', media(['/s.vtt']));
    bytes('/a.ts', ts());
    bytes('/s.vtt', ts()); // 媒体容器，但不是 WebVTT
    await expectLater(run(), code(SourceErrorCode.parse));
  });

  test('key must be 16 bytes; encrypted segment size limit', () async {
    text(
      '/index.m3u8',
      media(['/a.ts'], extra: '#EXT-X-KEY:METHOD=AES-128,URI="/k"\n'),
    );
    final key = Uint8List.fromList(List.generate(16, (i) => i));
    final iv = Uint8List(16);
    bytes('/a.ts', encrypt(ts(), key, iv));
    bytes('/k', key.sublist(0, 15));
    await expectLater(run(), code(SourceErrorCode.parse));

    bytes('/k', key);
    await expectLater(
      run(limits: const VideoDownloadLimits(maxEncryptedSegmentBytes: 100)),
      code(SourceErrorCode.limit),
    );
    // E_LIMIT 时删除该剧集已写的全部文件（含 video.json）。
    expect(dir.existsSync() && dir.listSync().isNotEmpty, isFalse);

    // 正常情况：存的是明文。
    await run();
    expect(written(), hasLength(1));
    expect(File(written().single).readAsBytesSync(), ts());
  });

  test('byte limit on the AES path deletes what was written', () async {
    text(
      '/index.m3u8',
      media([
        '/a.ts',
        '/b.ts',
      ], extra: '#EXT-X-KEY:METHOD=AES-128,URI="/k",IV=0x0\n'),
    );
    final key = Uint8List.fromList(List.generate(16, (i) => i));
    bytes('/k', key);
    bytes('/a.ts', encrypt(ts(), key, Uint8List(16)));
    bytes('/b.ts', encrypt(ts(), key, Uint8List(16)));
    await expectLater(
      run(limits: const VideoDownloadLimits(maxBytes: 2500, concurrency: 1)),
      code(SourceErrorCode.limit),
    );
    expect(dir.existsSync() && dir.listSync().isNotEmpty, isFalse);
  });

  test('byte-range segments need a matching 206', () async {
    text(
      '/index.m3u8',
      media(['/all.ts'], extra: '#EXT-X-BYTERANGE:940@188\n'),
    );
    bytes('/all.ts', ts()); // 忽略 Range，返回 200
    await expectLater(run(), code(SourceErrorCode.unsupported));

    bytes(
      '/all.ts',
      ts(940),
      status: 206,
      headers: {'content-range': 'bytes 0-939/1880'},
    );
    await expectLater(run(), code(SourceErrorCode.unsupported));

    // 起点一致但多给了数据。
    bytes(
      '/all.ts',
      ts(1880),
      status: 206,
      headers: {'content-range': 'bytes 188-1127/1880'},
    );
    await expectLater(run(), code(SourceErrorCode.parse));
    expect(written(), isEmpty);

    bytes(
      '/all.ts',
      ts(940),
      status: 206,
      headers: {'content-range': 'bytes 188-1127/1880'},
    );
    await run();
    expect(File(written().single).lengthSync(), 940);
  });

  test('playlist size limits', () async {
    text('/index.m3u8', media(List.generate(200, (i) => '/s$i.ts')));
    await expectLater(
      run(limits: const VideoDownloadLimits(maxPlaylistBytes: 1000)),
      code(SourceErrorCode.limit),
    );
    // 合计上限：主播放列表 + 子播放列表。
    text('/index.m3u8', '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\n/v.m3u8\n');
    text('/v.m3u8', media(List.generate(200, (i) => '/s$i.ts')));
    await expectLater(
      run(limits: const VideoDownloadLimits(maxTotalPlaylistBytes: 1000)),
      code(SourceErrorCode.limit),
    );
  });

  test(
    'segment count is checked per playlist, before fetching the rest',
    () async {
      text(
        '/index.m3u8',
        '#EXTM3U\n'
            '#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="s",NAME="1",URI="/s1.m3u8"\n'
            '#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="s",NAME="2",URI="/s2.m3u8"\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=1,SUBTITLES="s"\n/v.m3u8\n',
      );
      text('/v.m3u8', media(List.generate(10, (i) => '/s$i.ts')));
      await expectLater(
        run(limits: const VideoDownloadLimits(maxItems: 5)),
        code(SourceErrorCode.limit),
      );
      expect(
        hits.where((h) => h.contains('/s1.m3u8') || h.contains('/s2.m3u8')),
        isEmpty,
      );
    },
  );

  test('slow playlists hit the total time limit', () async {
    routes['/index.m3u8'] = (req) async {
      req.response.headers.set('content-type', 'application/vnd.apple.mpegurl');
      req.response.write('#EXTM3U\n');
      await req.response.flush();
      for (var i = 0; i < 50; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        req.response.write('#EXT-X-VERSION:3\n');
        await req.response.flush();
      }
      await req.response.close();
    };
    final started = DateTime.now();
    await expectLater(
      run(
        limits: const VideoDownloadLimits(
          metadataTimeout: Duration(milliseconds: 500),
        ),
      ),
      net(NetworkErrorKind.timeout),
    );
    expect(
      DateTime.now().difference(started),
      lessThan(const Duration(seconds: 3)),
    );
  });

  test('cancel aborts a segment request in flight', () async {
    text('/index.m3u8', media(['/slow.ts']));
    final arrived = Completer<void>();
    routes['/slow.ts'] = (req) async {
      req.response.headers.set('content-type', 'video/mp2t');
      req.response.add(ts());
      await req.response.flush();
      arrived.complete();
      // 之后一直不结束。
      await Future<void>.delayed(const Duration(seconds: 20));
      await req.response.close();
    };
    final abort = NetCancellation();
    final future = run(abort: abort);
    await arrived.future;
    final started = DateTime.now();
    abort.cancel();
    await expectLater(
      future,
      throwsA(
        isA<NetworkException>().having(
          (e) => e.kind,
          'kind',
          NetworkErrorKind.cancelled,
        ),
      ),
    );
    expect(
      DateTime.now().difference(started),
      lessThan(const Duration(seconds: 3)),
    );
    expect(written(), isEmpty, reason: '中止的分片不留下文件');
  });

  test('single file: 206 without a range request is not a whole file; source Range is dropped', () async {
    bytes(
      '/v.mp4',
      ts(),
      status: 206,
      headers: {'content-range': 'bytes 0-1879/9999'},
    );
    await expectLater(
      run(url: '/v.mp4', type: StreamType.mp4),
      code(SourceErrorCode.http),
    );

    String? seenRange;
    routes['/w.mp4'] = (req) {
      seenRange = req.headers.value('range');
      req.response.add(ts());
      return req.response.close();
    };
    await run(
      url: '/w.mp4',
      type: StreamType.mp4,
      headers: const {'Range': 'bytes=0-99'},
    );
    expect(seenRange, isNull);
    expect(File('${dir.path}/media.bin').lengthSync(), 1880);
  });

  test('single file: undeclared length counted against the limit', () async {
    routes['/big.mp4'] = (req) async {
      // 不声明长度（chunked）。
      for (var i = 0; i < 10; i++) {
        req.response.add(ts());
        await req.response.flush();
      }
      await req.response.close();
    };
    await expectLater(
      run(
        url: '/big.mp4',
        type: StreamType.mp4,
        limits: const VideoDownloadLimits(maxBytes: 5000),
      ),
      code(SourceErrorCode.limit),
    );
    expect(File('${dir.path}/media.bin').existsSync(), isFalse);
  });

  test('damaged video.json is treated as missing', () async {
    text('/index.m3u8', media(['/a.ts']));
    bytes('/a.ts', ts());
    await dir.create(recursive: true);
    File('${dir.path}/video.json').writeAsBytesSync([0xff, 0xfe, 0x00, 0x80]);
    await run();
    expect(
      jsonDecode(File('${dir.path}/video.json').readAsStringSync()),
      isA<Map>(),
    );
  });

  test('slow response headers count against the metadata time limit', () async {
    routes['/index.m3u8'] = (req) async {
      await Future<void>.delayed(const Duration(seconds: 3));
      req.response.write('#EXTM3U\n');
      await req.response.close();
    };
    final started = DateTime.now();
    await expectLater(
      run(
        limits: const VideoDownloadLimits(
          metadataTimeout: Duration(milliseconds: 500),
        ),
      ),
      net(NetworkErrorKind.timeout),
    );
    expect(
      DateTime.now().difference(started),
      lessThan(const Duration(seconds: 2)),
    );
  });

  test('slow key counts against the metadata time limit', () async {
    text(
      '/index.m3u8',
      media(['/a.ts'], extra: '#EXT-X-KEY:METHOD=AES-128,URI="/k"\n'),
    );
    bytes('/a.ts', List.filled(32, 1));
    routes['/k'] = (req) async {
      await Future<void>.delayed(const Duration(seconds: 3));
      req.response.add(List.filled(16, 1));
      await req.response.close();
    };
    final started = DateTime.now();
    await expectLater(
      run(
        limits: const VideoDownloadLimits(
          metadataTimeout: Duration(milliseconds: 500),
        ),
      ),
      net(NetworkErrorKind.timeout),
    );
    expect(
      DateTime.now().difference(started),
      lessThan(const Duration(seconds: 2)),
    );
  });

  test('resume: a 206 carrying a different ETag is not appended', () async {
    var version = 'A';
    final ranges = <String?>[];
    routes['/v.mp4'] = (req) {
      ranges.add(req.headers.value('range'));
      final body = ts(1880);
      if (version == 'B') body[1000] = 0x55;
      req.response.headers.set('etag', '"$version"');
      final range = req.headers.value('range');
      if (range != null) {
        // 忽略 If-Range，照样按区间返回新版本。
        final from = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)![1]!);
        req.response
          ..statusCode = 206
          ..headers.set('content-range', 'bytes $from-1879/1880');
        req.response
          ..contentLength = 1880 - from
          ..add(body.sublist(from));
      } else {
        req.response
          ..contentLength = body.length
          ..add(body);
      }
      return req.response.close();
    };
    await run(url: '/v.mp4', type: StreamType.mp4);
    final media = File('${dir.path}/media.bin');
    media.writeAsBytesSync(media.readAsBytesSync().sublist(0, 500));
    version = 'B';
    ranges.clear();
    await run(url: '/v.mp4', type: StreamType.mp4);
    expect(ranges, ['bytes=500-', null], reason: '续传被拒后从头下载');
    expect(media.readAsBytesSync()[1000], 0x55);
    expect(media.lengthSync(), 1880);
  });

  test('long quality labels and track names still read back', () async {
    text(
      '/index.m3u8',
      '#EXTM3U\n'
          '#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="s",NAME="${'名' * 400}",URI="/s.m3u8"\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=1,SUBTITLES="s",RESOLUTION=${'9' * 40}x1\n/v.m3u8\n',
    );
    text('/v.m3u8', media(['/a.ts']));
    text('/s.m3u8', media(['/s.vtt']));
    bytes('/a.ts', ts());
    bytes('/s.vtt', utf8.encode('WEBVTT\n\n00:00.000 --> 00:01.000\nx\n'));
    await VideoDownloadTask(
      client: client,
      baseUrl: Uri.parse('http://video.example.com'),
      content: VideoContent(
        streams: [
          StreamRef(
            url: '/index.m3u8',
            type: StreamType.hls,
            quality: 'q' * 400,
          ),
        ],
      ),
      preferredLabel: null,
      dir: dir,
      abort: NetCancellation(),
      onProgress: (_, _, _) async {},
    ).run();
    final m = VideoManifest.decode(
      File('${dir.path}/video.json').readAsStringSync(),
    );
    expect(m.label.length, 256);
    expect(m.tracks[1].name!.length, 256);
    expect(m.resolution, isNull);
  });

  test('E_LIMIT on a retry deletes the earlier partial download', () async {
    text('/index.m3u8', media(['/a.ts', '/b.ts']));
    bytes('/a.ts', ts());
    bytes('/b.ts', ts());
    await run();
    expect(written(), hasLength(2));
    text('/index.m3u8', media(List.generate(10, (i) => '/s$i.ts')));
    await expectLater(
      run(limits: const VideoDownloadLimits(maxItems: 5)),
      code(SourceErrorCode.limit),
    );
    expect(dir.existsSync() && dir.listSync().isNotEmpty, isFalse);
  });

  test('segments requested without a range must return 200, not 206', () async {
    text('/index.m3u8', media(['/a.ts']));
    bytes(
      '/a.ts',
      ts(),
      status: 206,
      headers: {'content-range': 'bytes 0-1879/18800'},
    );
    await expectLater(run(), code(SourceErrorCode.http));
    expect(written(), isEmpty);
  });

  test(
    'a small playlist read entirely in the peek still counts against the total',
    () async {
      text('/index.m3u8', '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\n/v.m3u8\n');
      text('/v.m3u8', media(['/a.ts', '/b.ts']));
      await expectLater(
        run(limits: const VideoDownloadLimits(maxTotalPlaylistBytes: 100)),
        code(SourceErrorCode.limit),
      );
    },
  );

  test(
    'a default Range header from the manifest never yields a partial file',
    () async {
      final withRange = DioSourceHttpClient(
        SourceNetworkConfig(
          sourceId: 'com.example.video',
          baseUrl: Uri.parse('http://video.example.com'),
          defaultHeaders: const {'Range': 'bytes=0-99'},
          timeout: const Duration(seconds: 5),
          maxRetries: 0,
        ),
        adapter: IOHttpClientAdapter(
          createHttpClient: () => HttpClient()
            ..connectionFactory = (uri, proxyHost, proxyPort) =>
                Socket.startConnect(
                  InternetAddress.loopbackIPv4,
                  upstream.port,
                ),
        ),
      );
      addTearDown(withRange.close);
      routes['/v.mp4'] = (req) {
        final body = ts();
        if (req.headers.value('range') != null) {
          req.response
            ..statusCode = 206
            ..headers.set('content-range', 'bytes 0-99/1880')
            ..add(body.sublist(0, 100));
        } else {
          req.response.add(body);
        }
        return req.response.close();
      };
      await expectLater(
        VideoDownloadTask(
          client: withRange,
          baseUrl: Uri.parse('http://video.example.com'),
          content: const VideoContent(
            streams: [StreamRef(url: '/v.mp4', type: StreamType.mp4)],
          ),
          preferredLabel: null,
          dir: dir,
          abort: NetCancellation(),
          onProgress: (_, _, _) async {},
        ).run(),
        code(SourceErrorCode.http),
      );
      expect(File('${dir.path}/media.bin').existsSync(), isFalse);
    },
  );
}
