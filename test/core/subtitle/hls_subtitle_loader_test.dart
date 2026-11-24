import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/network/dio_source_http_client.dart';
import 'package:tsumugi/core/network/media/media_proxy.dart';
import 'package:tsumugi/core/network/network_exception.dart';
import 'package:tsumugi/core/network/source_http_client.dart';
import 'package:tsumugi/core/subtitle/hls_subtitle_loader.dart';
import 'package:tsumugi/core/subtitle/subtitle_parser.dart';

import '../network/mock_support.dart';

Duration _s(num seconds) => Duration(microseconds: (seconds * 1e6).round());

/// 可自定义响应的上游：虚构主机名的连接都接到这里，白名单仍按主机名检查。
class _Upstream {
  _Upstream._(this._server) {
    _server.listen((req) async {
      requests.add(req.uri.path);
      final handler = routes[req.uri.path];
      if (handler == null) {
        req.response.statusCode = 404;
        return req.response.close();
      }
      await handler(req);
    });
  }

  static Future<_Upstream> start() async =>
      _Upstream._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;
  final requests = <String>[];
  final routes = <String, Future<void> Function(HttpRequest req)>{};

  void text(String path, String body, {String type = 'text/plain'}) =>
      routes[path] = (req) {
        req.response.headers.set('content-type', type);
        req.response.add(utf8.encode(body));
        return req.response.close();
      };

  DioSourceHttpClient client() => DioSourceHttpClient(
    SourceNetworkConfig(
      sourceId: 'com.example.crafted',
      baseUrl: Uri.parse('http://video.example.com'),
      allowedHosts: const ['cdn.example.com'],
      timeout: const Duration(seconds: 5),
      retryBaseDelay: const Duration(milliseconds: 10),
      maxRetries: 0,
    ),
    adapter: IOHttpClientAdapter(
      createHttpClient: () =>
          HttpClient()
            ..connectionFactory = (uri, proxyHost, proxyPort) =>
                Socket.startConnect(InternetAddress.loopbackIPv4, _server.port),
    ),
  );

  Future<void> close() => _server.close(force: true);
}

String _vtt(String cues, {String? map}) =>
    'WEBVTT\n${map == null ? '' : 'X-TIMESTAMP-MAP=$map\n'}\n$cues\n';

void main() {
  group('hlsCueTime', () {
    test('按 X-TIMESTAMP-MAP 换算并减去开始时间（mock 素材：MPEGTS 126000 = 1.4 s）', () {
      const map = WebVttTimestampMap(Duration.zero, 126000);
      expect(hlsCueTime(Duration.zero, map, _s(1.4)), Duration.zero);
      expect(hlsCueTime(_s(2), map, _s(1.4)), _s(2));
      // 与 LOCAL 偏移、开始时间不同的组合。
      expect(
        hlsCueTime(_s(15), WebVttTimestampMap(_s(10), 900000), _s(10)),
        _s(5),
      );
    });

    test('没有 X-TIMESTAMP-MAP：cue 时间 0 对应 MPEG-TS 时间 0（RFC 8216 §3.5）', () {
      expect(hlsCueTime(_s(3), null, _s(1.4)), _s(1.6));
      expect(hlsCueTime(_s(1), null, Duration.zero), _s(1));
    });

    test('33 位时间戳回绕：差值折回到离 0 最近的值', () {
      // 视频 PTS 已回绕到接近 0，字幕的 MPEGTS 还在回绕之前。
      final beforeWrap = WebVttTimestampMap(Duration.zero, mpegTsWrap - 90000);
      expect(hlsCueTime(_s(3), beforeWrap, _s(1)), _s(1));
      // 反过来：开始时间在回绕之前，字幕的 MPEGTS 已回绕。
      final start = Duration(microseconds: (mpegTsWrap - 90000) * 100 ~/ 9);
      expect(
        hlsCueTime(_s(1), const WebVttTimestampMap(Duration.zero, 0), start),
        _s(2),
      );
    });
  });

  group('parseHlsSubtitlePlaylist', () {
    final base = Uri.parse('http://127.0.0.1:1/tok/0/index.m3u8');

    test('EXTINF 累加为开始时间；地址相同的只留第一个', () {
      final segments = parseHlsSubtitlePlaylist(
        '#EXTM3U\n#EXT-X-TARGETDURATION:6\n'
        '#EXTINF:6.0,\n/tok/1/sub.vtt\n'
        '#EXT-X-BYTERANGE:10@0\n#EXTINF:4.5,\n/tok/2/sub.vtt\n'
        '#EXT-X-BYTERANGE:10@10\n#EXTINF:4.5,\n/tok/2/sub.vtt\n'
        '#EXTINF:bad,\n/tok/3/sub.vtt\n#EXT-X-ENDLIST\n',
        base,
      );
      expect(segments, [
        HlsSubtitleSegment(base.resolve('/tok/1/sub.vtt'), Duration.zero),
        HlsSubtitleSegment(base.resolve('/tok/2/sub.vtt'), _s(6)),
        HlsSubtitleSegment(base.resolve('/tok/3/sub.vtt'), _s(15)),
      ]);
    });

    test('不是播放列表、分片过多时拒绝', () {
      expect(
        () => parseHlsSubtitlePlaylist('WEBVTT\n', base),
        throwsA(isA<SubtitleFormatException>()),
      );
      final many = StringBuffer('#EXTM3U\n');
      for (var i = 0; i < 4; i++) {
        many.write('#EXTINF:1,\n/tok/$i/sub.vtt\n');
      }
      expect(
        parseHlsSubtitlePlaylist('$many', base, maxSegments: 4),
        hasLength(4),
      );
      many.write('#EXTINF:1,\n/tok/9/sub.vtt\n');
      expect(
        () => parseHlsSubtitlePlaylist('$many', base, maxSegments: 4),
        throwsA(isA<SubtitleFormatException>()),
      );
    });

    test('取的顺序：从播放位置所在的分片向后，再向前', () {
      final segments = [
        for (var i = 0; i < 5; i++)
          HlsSubtitleSegment(base.resolve('/tok/$i/sub.vtt'), _s(i * 2)),
      ];
      expect(hlsSubtitleFetchOrder(segments, _s(5)), [2, 3, 4, 1, 0]);
      expect(hlsSubtitleFetchOrder(segments, Duration.zero), [0, 1, 2, 3, 4]);
      expect(hlsSubtitleFetchOrder(segments, _s(100)), [4, 3, 2, 1, 0]);
    });
  });

  group('经代理会话取回', () {
    late MockServer server;
    late MediaProxy proxy;
    late DioSourceHttpClient client;
    final http = HttpClient();

    setUpAll(() async => server = await MockServer.start());
    tearDownAll(() async {
      http.close(force: true);
      await server.close();
    });
    setUp(() async {
      proxy = await MediaProxy.start(
        prepareTimeout: const Duration(seconds: 2),
      );
      client = mockClient(
        server,
        sourceId: 'com.example.video',
        baseUrl: 'http://video.example.com',
      );
    });
    tearDown(() async {
      await proxy.close();
      client.close();
    });

    /// 像播放器一样取一次主播放列表（会话由此登记字幕轨）。
    Future<void> fetchMaster(Uri url) async {
      final res = await (await http.getUrl(url)).close();
      expect(res.statusCode, 200);
      final body = await utf8.decodeStream(res);
      expect(body, isNot(contains('TYPE=SUBTITLES')));
    }

    test('mock 素材：三条都在正确的位置，文字不带下一分片的头部（#84）', () async {
      final session = proxy.open(
        client: client,
        url: Uri.parse(
          'http://video.example.com/video/media/hls/master_sub.m3u8',
        ),
      );
      await fetchMaster(session.url);
      final track = session.subtitleTracks.single;
      expect((track.name, track.language), ('HLS Chinese', 'zh'));
      final progress = <List<SubtitleCue>>[];
      final doc = await loadHlsSubtitles(
        Uri.parse(track.url),
        presentationStart: _s(1.4),
        position: _s(2.5),
        concurrency: 1,
        progressInterval: Duration.zero,
        onProgress: (d) => progress.add(d.cues),
      );
      expect(doc.cues, [
        SubtitleCue(Duration.zero, _s(2), 'HLS subtitle 1'),
        SubtitleCue(_s(2), _s(4), 'HLS subtitle 2'),
        SubtitleCue(_s(4), _s(6), 'HLS subtitle 3'),
      ]);
      expect(doc.textAt(_s(1)), 'HLS subtitle 1');
      // 从播放位置所在的分片开始：第一批只有第 2 条。
      expect(progress.first.map((c) => c.text), ['HLS subtitle 2']);
      expect(progress.last, hasLength(3));
      session.close();
    });

    test('本地来源会话（离线回放）同样可取', () async {
      final dir = await Directory.systemTemp.createTemp('tsumugi_hls_sub_');
      addTearDown(() => dir.delete(recursive: true));
      final hls = 'test/fixtures/mock_site/video/hls';
      final session = proxy.openLocal(
        root: 'index.m3u8',
        playlists: {
          'index.m3u8':
              '#EXTM3U\n'
              '#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="HLS Chinese",LANGUAGE="zh",URI="s0/index.m3u8"\n'
              '#EXT-X-STREAM-INF:BANDWIDTH=1,SUBTITLES="subs"\nv/index.m3u8\n',
          'v/index.m3u8': '#EXTM3U\n#EXTINF:2,\nv/00000.ts\n#EXT-X-ENDLIST\n',
          's0/index.m3u8':
              '#EXTM3U\n#EXTINF:2,\ns0/00000.vtt\n#EXTINF:2,\ns0/00001.vtt\n'
              '#EXTINF:2,\ns0/00002.vtt\n#EXT-X-ENDLIST\n',
        },
        files: {
          for (var i = 0; i < 3; i++)
            's0/0000$i.vtt': LocalMediaFile(
              File('$hls/sub$i.vtt'),
              LocalMediaKind.subtitle,
            ),
          'v/00000.ts': LocalMediaFile(
            File('$hls/seg0.ts'),
            LocalMediaKind.media,
            extension: 'ts',
          ),
        },
      );
      final track = session.subtitleTracks.single;
      final doc = await loadHlsSubtitles(
        Uri.parse(track.url),
        presentationStart: _s(1.4),
      );
      expect(doc.cues.map((c) => (c.start, c.text)), [
        (Duration.zero, 'HLS subtitle 1'),
        (_s(2), 'HLS subtitle 2'),
        (_s(4), 'HLS subtitle 3'),
      ]);
      session.close();
    });

    test('只接受本地媒体代理（回环地址）的地址', () async {
      await expectLater(
        loadHlsSubtitles(
          Uri.parse('http://video.example.com/a/0/index.m3u8'),
          presentationStart: Duration.zero,
        ),
        throwsArgumentError,
      );
      await expectLater(
        loadHlsSubtitles(
          Uri.parse('http://127.0.0.1:1/index.m3u8'),
          presentationStart: Duration.zero,
        ),
        throwsArgumentError,
      );
    });
  });

  group('构造的上游（代理的限制照常生效）', () {
    late _Upstream up;
    late DioSourceHttpClient client;
    late MediaProxy proxy;
    final http = HttpClient();

    setUp(() async {
      up = await _Upstream.start();
      client = up.client();
      proxy = await MediaProxy.start(
        prepareTimeout: const Duration(seconds: 2),
      );
    });
    tearDown(() async {
      await proxy.close();
      client.close();
      await up.close();
    });
    tearDownAll(() => http.close(force: true));

    late MediaProxySession session;

    /// 主播放列表指向 [subs]（相对于 video.example.com），返回该字幕轨的代理地址（会话记在 [session]）。
    Future<Uri> track(String subs) async {
      up.text(
        '/master.m3u8',
        '#EXTM3U\n'
            '#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="s",NAME="x",URI="$subs"\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=1,SUBTITLES="s"\nv.m3u8\n',
      );
      session = proxy.open(
        client: client,
        url: Uri.parse('http://video.example.com/master.m3u8'),
      );
      await (await (await http.getUrl(session.url)).close()).drain<void>();
      return Uri.parse(session.subtitleTracks.single.url);
    }

    test('失败的分片跳过：404、非 WebVTT（415）、白名单外（403）、过大；跨分片重复的 cue 只留一条', () async {
      up
        ..text(
          '/s.m3u8',
          '#EXTM3U\n'
              '#EXTINF:2,\nok0.vtt\n#EXTINF:2,\nmissing.vtt\n#EXTINF:2,\nhtml.vtt\n'
              '#EXTINF:2,\nhttp://outside.example.net/x.vtt\n#EXTINF:2,\nbig.vtt\n'
              '#EXTINF:2,\nhttp://cdn.example.com/ok1.vtt\n',
        )
        ..text('/ok0.vtt', _vtt('00:00.000 --> 00:03.000\nA'))
        ..text('/html.vtt', '<html>error</html>')
        ..text('/big.vtt', _vtt('00:00.000 --> 00:01.000\n${'x' * 5000}'))
        // 与 ok0 重复的一条（跨分片）与一条新的；没有 X-TIMESTAMP-MAP。
        ..text(
          '/ok1.vtt',
          _vtt('00:00.000 --> 00:03.000\nA\n\n00:10.000 --> 00:11.000\nB'),
        );
      final doc = await loadHlsSubtitles(
        await track('s.m3u8'),
        presentationStart: Duration.zero,
        maxSegmentBytes: 4096,
      );
      expect(doc.cues, [
        SubtitleCue(Duration.zero, _s(3), 'A'),
        SubtitleCue(_s(10), _s(11), 'B'),
      ]);
      expect(up.requests, isNot(contains('/x.vtt')), reason: '白名单外不发请求');
    });

    test('全部分片失败时抛第一个错误；字幕播放列表不是播放列表时失败', () async {
      up
        ..text('/s.m3u8', '#EXTM3U\n#EXTINF:2,\nhtml.vtt\n')
        ..text('/html.vtt', '<html>')
        ..text('/bad.m3u8', '<html>not a playlist</html>');
      await expectLater(
        loadHlsSubtitles(
          await track('s.m3u8'),
          presentationStart: Duration.zero,
        ),
        throwsA(isA<NetworkException>().having((e) => e.status, 'status', 415)),
      );
      await expectLater(
        loadHlsSubtitles(
          await track('bad.m3u8'),
          presentationStart: Duration.zero,
        ),
        throwsA(isA<NetworkException>().having((e) => e.status, 'status', 502)),
      );
    });

    test('字幕播放列表在白名单外：403', () async {
      await expectLater(
        loadHlsSubtitles(
          await track('http://outside.example.net/s.m3u8'),
          presentationStart: Duration.zero,
        ),
        throwsA(isA<NetworkException>().having((e) => e.status, 'status', 403)),
      );
      expect(up.requests, isNot(contains('/s.m3u8')));
    });

    test('没有分片时为空时间轴', () async {
      up.text('/s.m3u8', '#EXTM3U\n#EXT-X-ENDLIST\n');
      final doc = await loadHlsSubtitles(
        await track('s.m3u8'),
        presentationStart: Duration.zero,
      );
      expect(doc.cues, isEmpty);
    });

    test('合计大小达到上限时停止再取，已取到的照常返回', () async {
      final playlist = StringBuffer('#EXTM3U\n');
      for (var i = 0; i < 6; i++) {
        playlist.write('#EXTINF:1,\n$i.vtt\n');
        up.text('/$i.vtt', _vtt('00:0$i.000 --> 00:0$i.500\nc$i'));
      }
      up.text('/s.m3u8', '$playlist');
      final one = utf8.encode(_vtt('00:00.000 --> 00:00.500\nc0')).length;
      final doc = await loadHlsSubtitles(
        await track('s.m3u8'),
        presentationStart: Duration.zero,
        concurrency: 1,
        maxTotalBytes: one * 2,
      );
      expect(doc.cues.map((c) => c.text), ['c0', 'c1']);
      // 预算恰好用完：不再请求第 3 个分片。
      expect(up.requests.where((p) => p.endsWith('.vtt')), hasLength(2));
    });

    test('单个请求超时：该分片跳过', () async {
      up
        ..text('/s.m3u8', '#EXTM3U\n#EXTINF:1,\nslow.vtt\n#EXTINF:1,\nok.vtt\n')
        ..routes['/slow.vtt'] = (req) async {
          req.response.headers.set('content-type', 'text/vtt');
          req.response.write('WEBVTT\n\n');
          await req.response.flush();
          await Future<void>.delayed(const Duration(seconds: 3));
          await req.response.close();
        }
        ..text('/ok.vtt', _vtt('00:01.000 --> 00:02.000\nok'));
      final watch = Stopwatch()..start();
      final doc = await loadHlsSubtitles(
        await track('s.m3u8'),
        presentationStart: Duration.zero,
        requestTimeout: const Duration(milliseconds: 400),
      );
      expect(doc.cues.map((c) => c.text), ['ok']);
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('响应头已到之后超时：断开连接（代理随之取消上游），不在后台继续读', () async {
      up
        ..text('/s.m3u8', '#EXTM3U\n#EXTINF:1,\nslow.vtt\n#EXTINF:1,\nok.vtt\n')
        ..routes['/slow.vtt'] = (req) async {
          req.response.headers.set('content-type', 'text/vtt');
          // 足够让代理识别为 WebVTT 并开始转发，之后一直慢慢发。
          req.response.write('WEBVTT\n\n${'NOTE ${'x' * 2000}\n\n'}');
          await req.response.flush();
          try {
            for (var i = 0; i < 100; i++) {
              await Future<void>.delayed(const Duration(milliseconds: 100));
              req.response.write('NOTE y\n\n');
              await req.response.flush();
            }
          } catch (_) {}
          await req.response.close().catchError((_) {});
        }
        ..text('/ok.vtt', _vtt('00:01.000 --> 00:02.000\nok'));
      final doc = await loadHlsSubtitles(
        await track('s.m3u8'),
        presentationStart: Duration.zero,
        concurrency: 1,
        requestTimeout: const Duration(milliseconds: 500),
      );
      expect(doc.cues.map((c) => c.text), ['ok']);
      // 字幕层断开后，代理在途的上游请求随之取消。
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (session.inFlight > 0 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(session.inFlight, 0);
    });

    test('合计预算按读到的字节计：失败分片已读的部分也算，耗尽后不再请求', () async {
      final playlist = StringBuffer('#EXTM3U\n');
      for (var i = 0; i < 10; i++) {
        playlist.write('#EXTINF:1,\nbig$i.vtt\n');
        // 没有 Content-Length、超过单片上限：读到上限才失败。
        up.routes['/big$i.vtt'] = (req) async {
          req.response.headers.set('content-type', 'text/vtt');
          req.response.write('WEBVTT\n\n${'x' * 2000}');
          await req.response.flush(); // 分块传输：没有 Content-Length
          req.response.write('x' * 4000);
          await req.response.close();
        };
      }
      up.text('/s.m3u8', '$playlist');
      await expectLater(
        loadHlsSubtitles(
          await track('s.m3u8'),
          presentationStart: Duration.zero,
          concurrency: 1,
          maxSegmentBytes: 4096,
          maxTotalBytes: 10000,
        ),
        throwsA(isA<SubtitleFormatException>()),
      );
      // 每个失败分片约读 2 KB 即超过单片上限；10000 字节的预算约 5 个分片后耗尽（不会把 10 个都请求一遍）。
      expect(
        up.requests.where((p) => p.startsWith('/big')).length,
        lessThanOrEqualTo(6),
      );
    });

    test('错误中的地址不含会话令牌', () async {
      up.text('/s.m3u8', '#EXTM3U\n#EXTINF:1,\nmissing.vtt\n');
      final url = await track('s.m3u8');
      final token = url.pathSegments.first;
      Object? error;
      final logs = <String>[];
      try {
        await loadHlsSubtitles(
          url,
          presentationStart: Duration.zero,
          log: logs.add,
        );
      } catch (e) {
        error = e;
      }
      expect(error, isA<NetworkException>());
      expect('$error', isNot(contains(token)));
      expect((error! as NetworkException).uri!.pathSegments.first, '-');
      expect(logs, isNotEmpty);
      expect(logs.join('\n'), isNot(contains(token)));
    });

    test('取消：中止进行中的请求并抛 cancelled', () async {
      final started = Completer<void>();
      up
        ..text('/s.m3u8', '#EXTM3U\n#EXTINF:1,\nhang.vtt\n')
        ..routes['/hang.vtt'] = (req) async {
          started.complete();
          await Future<void>.delayed(const Duration(seconds: 5));
          await req.response.close();
        };
      final cancel = NetCancellation();
      final future = loadHlsSubtitles(
        await track('s.m3u8'),
        presentationStart: Duration.zero,
        cancellation: cancel,
      );
      await started.future;
      final watch = Stopwatch()..start();
      cancel.cancel();
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
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    });
  });

  test('只请求同一会话的地址：其他令牌、其他端口与非回环地址的分片不请求', () async {
    final requests = <String>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) {
      requests.add(req.uri.path);
      final res = req.response;
      if (req.uri.path == '/tok/0/index.m3u8') {
        res
          ..headers.set('content-type', 'application/vnd.apple.mpegurl')
          ..write(
            '#EXTM3U\n'
            '#EXTINF:1,\n/tok/1/sub.vtt\n'
            '#EXTINF:1,\n/other/2/sub.vtt\n'
            '#EXTINF:1,\n/tok/3/extra/sub.vtt\n'
            '#EXTINF:1,\nhttp://127.0.0.1:1/tok/4/sub.vtt\n'
            '#EXTINF:1,\nhttp://video.example.com/tok/5/sub.vtt\n',
          );
      } else {
        res
          ..headers.set('content-type', 'text/vtt')
          ..write(_vtt('00:00.000 --> 00:01.000\n${req.uri.path}'));
      }
      res.close();
    });
    final doc = await loadHlsSubtitles(
      Uri.parse('http://127.0.0.1:${server.port}/tok/0/index.m3u8'),
      presentationStart: Duration.zero,
    );
    expect(doc.cues.map((c) => c.text), ['/tok/1/sub.vtt']);
    expect(requests, ['/tok/0/index.m3u8', '/tok/1/sub.vtt']);
  });
}
