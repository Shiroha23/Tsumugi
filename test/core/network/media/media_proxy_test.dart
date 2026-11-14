import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/network/dio_source_http_client.dart';
import 'package:tsumugi/core/network/media/media_proxy.dart';
import 'package:tsumugi/core/network/network_exception.dart';
import 'package:tsumugi/core/network/source_http_client.dart';

import '../mock_support.dart';

/// 播放器一侧：直接用 dart:io 访问代理（不经源的网络层）。
class _Player {
  final _client = HttpClient()..userAgent = 'libmpv';

  Future<(int, Map<String, String>, Uint8List)> get(
    Uri url, {
    String method = 'GET',
    Map<String, String> headers = const {},
  }) async {
    final req = await _client.openUrl(method, url);
    headers.forEach(req.headers.set);
    final res = await req.close();
    final bytes = await res.fold<BytesBuilder>(
      BytesBuilder(),
      (b, c) => b..add(c),
    );
    final h = <String, String>{};
    res.headers.forEach((k, v) => h[k] = v.join(', '));
    return (res.statusCode, h, bytes.takeBytes());
  }

  Future<String> text(Uri url) async {
    final (status, _, body) = await get(url);
    expect(status, 200, reason: 'GET $url');
    return utf8.decode(body);
  }

  void close() => _client.close(force: true);
}

/// 可自定义响应的上游（任意虚构主机名都接到这里），用于构造 mock 服务器没有的情形。
class _Upstream {
  _Upstream._(this._server) {
    _server.listen((req) async {
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
  final routes = <String, Future<void> Function(HttpRequest req)>{};

  /// 以固定字节响应 [path]。
  void bytes(
    String path,
    List<int> body, {
    String type = 'application/octet-stream',
    Map<String, String> headers = const {},
  }) => routes[path] = (req) {
    req.response.headers.set('content-type', type);
    headers.forEach(req.response.headers.set);
    req.response.add(body);
    return req.response.close();
  };

  DioSourceHttpClient client() => DioSourceHttpClient(
    SourceNetworkConfig(
      sourceId: 'com.example.crafted',
      baseUrl: Uri.parse('http://video.example.com'),
      timeout: const Duration(seconds: 5),
      retryBaseDelay: const Duration(milliseconds: 10),
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

Uint8List fixture(String name) =>
    File('test/fixtures/mock_site/video/$name').readAsBytesSync();

/// 播放列表中的代理地址（非注释行与 URI 属性）。
List<Uri> proxiedUris(String playlist) => [
  for (final line in const LineSplitter().convert(playlist))
    if (line.isNotEmpty && !line.startsWith('#'))
      Uri.parse(line)
    else
      for (final m in RegExp(r'URI="([^"]*)"').allMatches(line))
        Uri.parse(m[1]!),
];

/// 一个最小的 MP4 文件头（`ftyp` 盒）后接若干字节。
Uint8List fakeMp4([int extra = 2048]) => Uint8List.fromList([
  0, 0, 0, 0x18, ...ascii.encode('ftypisom'), 0, 0, 2, 0, //
  ...ascii.encode('isomiso2'),
  for (var i = 0; i < extra; i++) i % 251,
]);

void main() {
  late MockServer server;
  late DioSourceHttpClient client;
  late MediaProxy proxy;
  late _Player player;

  setUpAll(() async => server = await MockServer.start());
  tearDownAll(() => server.close());

  setUp(() async {
    server.requests.clear();
    client = mockClient(
      server,
      sourceId: 'com.example.video',
      baseUrl: 'http://video.example.com',
      allowedHosts: const ['cdn.example.com'],
      headers: {'User-Agent': 'TsumugiTest'},
    );
    proxy = await MediaProxy.start(
      prepareTimeout: const Duration(milliseconds: 800),
    );
    player = _Player();
  });
  tearDown(() async {
    player.close();
    await proxy.close();
    client.close();
  });

  Iterable<RecordedRequest> upstream(String pathPrefix) =>
      server.requests.where((r) => r.path.startsWith(pathPrefix));

  MediaProxySession open(String url, {Map<String, String>? headers}) =>
      proxy.open(client: client, url: Uri.parse(url), headers: headers ?? {});

  group('MP4', () {
    test('经源客户端取得，带上 StreamRef.headers、默认 headers 与 Cookie，不带播放器 UA', () async {
      await client.setCookie('http://video.example.com/', 'sid', 'abc');
      final session = open(
        'http://video.example.com/video/media/clip.mp4',
        headers: {'X-Stream': '1', 'Accept-Encoding': 'br'},
      );
      expect(session.url.host, '127.0.0.1');
      expect(session.url.toString(), isNot(contains('example.com')));
      // 文件名由代理决定：只保留常见媒体扩展名。
      expect(session.url.pathSegments.last, 'media.mp4');

      final (status, headers, body) = await player.get(session.url);
      expect(status, 200);
      expect(body, fixture('clip.mp4'));
      // Content-Type 由代理决定，不透传上游的值。
      expect(headers['content-type'], 'application/octet-stream');
      expect(headers['accept-ranges'], 'bytes');

      final r = upstream('/video/media/clip.mp4').single;
      expect(r.host, 'video.example.com');
      expect(r.headers['x-stream'], '1');
      expect(r.headers['user-agent'], 'TsumugiTest');
      expect(r.headers['cookie'], contains('sid=abc'));
      // StreamRef.headers 不能覆盖 Accept-Encoding。
      expect(r.headers['accept-encoding'], 'identity');
    });

    test('Range 原样转发；从中间开始时先确认格式（一次）；根地址的 bytes=0- 不转发', () async {
      final session = open('http://video.example.com/video/media/clip.mp4');
      final clip = fixture('clip.mp4');
      final (s1, h1, b1) = await player.get(
        session.url,
        headers: {'range': 'bytes=4-7'},
      );
      expect(s1, 206);
      expect(h1['content-range'], 'bytes 4-7/${clip.length}');
      expect(utf8.decode(b1), 'ftyp');

      final (s2, _, b2) = await player.get(
        session.url,
        headers: {'range': 'bytes=100-199'},
      );
      expect(s2, 206);
      expect(b2, clip.sublist(100, 200));

      final (s3, _, b3) = await player.get(
        session.url,
        headers: {'range': 'bytes=0-'},
      );
      expect(s3, 200);
      expect(b3.length, clip.length);
      expect(upstream('/video/media/clip.mp4').map((r) => r.headers['range']), [
        'bytes=0-1023',
        'bytes=4-7',
        'bytes=100-199',
        null,
      ]);
    });

    test('HEAD 只返回响应头', () async {
      final session = open('http://video.example.com/video/media/clip.mp4');
      final (status, headers, body) = await player.get(
        session.url,
        method: 'HEAD',
      );
      expect(status, 200);
      expect(body, isEmpty);
      expect(headers['content-length'], '${fixture('clip.mp4').length}');
    });
  });

  group('HLS', () {
    test('主 / 子播放列表被改写，AES-128 分片由代理解密', () async {
      final session = open(
        'http://video.example.com/video/media/hls/master.m3u8',
      );
      final master = await player.text(session.url);
      expect(master, startsWith('#EXTM3U'));
      expect(master, isNot(contains('example.com')));
      final variant = proxiedUris(master).single;
      expect(variant.host, '127.0.0.1');
      expect(variant.pathSegments.last, 'index.m3u8');

      final media = await player.text(variant);
      expect(media, isNot(contains('example.com')));
      // 密钥由代理使用，播放器看不到 EXT-X-KEY。
      expect(media, isNot(contains('EXT-X-KEY')));
      final uris = proxiedUris(media);
      expect(uris.map((u) => u.pathSegments.last), [
        'media.ts',
        'media.ts',
        'media.ts',
      ]);
      expect(uris.toSet(), hasLength(3));
      for (final (i, u) in uris.indexed) {
        final (status, headers, plain) = await player.get(u);
        expect(status, 200);
        expect(headers['content-type'], 'application/octet-stream');
        expect(plain[0], 0x47, reason: '解密后为 MPEG-TS');
        expect(plain.length % 188, 0);
        expect(plain, isNot(fixture('hls/seg$i.ts')));
      }
      // 同一会话中密钥只取一次。
      expect(upstream('/video/media/hls/key.bin'), hasLength(1));
      expect(upstream('/video/').map((r) => r.host).toSet(), {
        'video.example.com',
      });
      // 同一地址在会话内只登记一次：再取一次播放列表得到相同的代理地址。
      expect(proxiedUris(await player.text(variant)), uris);
    });

    test('HEAD 根播放列表：返回改写后的类型与长度', () async {
      final session = open(
        'http://video.example.com/video/media/hls/master.m3u8',
      );
      final (status, headers, body) = await player.get(
        session.url,
        method: 'HEAD',
      );
      expect(status, 200);
      expect(body, isEmpty);
      expect(headers['content-type'], 'application/vnd.apple.mpegurl');
      final full = await player.get(session.url);
      expect(headers['content-length'], '${full.$3.length}');
    });

    test('需要 Referer 与 Cookie：经源会话取得的 Cookie 对密钥请求有效', () async {
      final session = open(
        'http://video.example.com/video/protected/hls/master.m3u8',
        headers: {'Referer': 'http://video.example.com/video/show/1'},
      );
      final media = await player.text(
        proxiedUris(await player.text(session.url)).single,
      );
      final seg = proxiedUris(media).first;

      final (noCookie, _, _) = await player.get(seg);
      expect(noCookie, 403, reason: '还没有 vtoken Cookie，取不到密钥');
      expect(session.lastFailure, isNull, reason: '上游 403 不是网络层错误');

      // 打开详情页时站点种下 vtoken（与真实流程一样经源客户端）。
      await client.getText('/video/show/1');
      final (status, _, plain) = await player.get(seg);
      expect(status, 200);
      expect(plain[0], 0x47);
    });

    test('经重定向取得的播放列表按最终地址解析相对路径（分片与密钥）', () async {
      final session = open(
        'http://video.example.com/redirect?to=%2Fvideo%2Fmedia%2Fhls%2Findex.m3u8',
      );
      final uris = proxiedUris(await player.text(session.url));
      final (status, _, body) = await player.get(uris.first);
      expect(status, 200);
      expect(body[0], 0x47);
      expect(upstream('/video/media/hls/key.bin'), hasLength(1));
      expect(upstream('/video/media/hls/seg0.ts'), hasLength(1));
    });

    test('白名单外的分片、重定向到白名单外、文本“分片”都被拒绝', () async {
      final session = open(
        'http://video.example.com/video/media/hls/mixed.m3u8',
      );
      final playlist = await player.text(session.url);
      expect(playlist, isNot(contains('example')));
      final uris = proxiedUris(playlist);
      expect(uris, hasLength(4));

      final statuses = [for (final u in uris) (await player.get(u)).$1];
      // 第 1 个分片是加密的 TS，但这个列表里没有 EXT-X-KEY：密文无法识别为媒体。
      expect(statuses, [415, 403, 403, 415]);
      expect(session.lastFailure?.kind, NetworkErrorKind.hostNotAllowed);
      expect(
        server.requests.where((r) => r.host == 'outside.example.net'),
        isEmpty,
      );
      expect(upstream('/redirect'), hasLength(1));
    });

    test('人机验证：返回 403，原因记在 lastFailure', () async {
      final session = open('http://video.example.com/challenge/page');
      expect((await player.get(session.url)).$1, 403);
      expect(session.lastFailure?.kind, NetworkErrorKind.challenge);
      expect(client.session.lastChallengeUrl?.path, '/challenge/page');
    });
  });

  group('构造的上游响应', () {
    late _Upstream up;
    late DioSourceHttpClient crafted;
    setUp(() async {
      up = await _Upstream.start();
      crafted = up.client();
    });
    tearDown(() async {
      crafted.close();
      await up.close();
    });

    MediaProxySession openCrafted(String path) => proxy.open(
      client: crafted,
      url: Uri.parse('http://video.example.com$path'),
    );

    test('HLS 以外的播放列表（任何编码）与文本一律 415', () async {
      const pls = '[playlist]\nFile1=http://outside.example.net/a.mp4\n';
      up
        ..bytes('/utf16.pls', [
          0xFF,
          0xFE,
          for (final c in pls.codeUnits) ...[c, 0],
        ])
        ..bytes('/plain.m3u', utf8.encode('http://outside.example.net/a.mp4\n'))
        ..bytes('/a.mpd', utf8.encode('<?xml version="1.0"?><MPD/>'))
        ..bytes('/ffconcat', utf8.encode('ffconcat version 1.0\nfile x\n'))
        ..bytes(
          '/fake.mp4',
          utf8.encode('#EXTM3U\n#EXTINF:1,\nhttp://outside.example.net/x.ts\n'),
          type: 'video/mp4',
        );
      for (final path in ['/utf16.pls', '/plain.m3u', '/a.mpd', '/ffconcat']) {
        expect((await player.get(openCrafted(path).url)).$1, 415, reason: path);
      }
      // 根地址是 HLS 播放列表时照常改写（白名单外的地址交给代理判断）。
      final hls = await player.text(openCrafted('/fake.mp4').url);
      expect(hls, isNot(contains('outside')));
    });

    test('播放列表中的“分片”若是播放列表，不交给播放器', () async {
      up
        ..bytes('/list.m3u8', utf8.encode('#EXTM3U\n#EXTINF:1,\nnested.ts\n'))
        ..bytes(
          '/nested.ts',
          utf8.encode('#EXTM3U\n#EXTINF:1,\nhttp://outside.example.net/x.ts\n'),
        );
      final playlist = await player.text(openCrafted('/list.m3u8').url);
      expect((await player.get(proxiedUris(playlist).single)).$1, 415);
    });

    test('字幕播放列表中的 WebVTT 可以取得，其他文本不行', () async {
      up
        ..bytes(
          '/master.m3u8',
          utf8.encode(
            '#EXTM3U\n'
            '#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="s",NAME="ja",URI="subs.m3u8"\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=1,SUBTITLES="s"\nv.m3u8\n',
          ),
        )
        ..bytes(
          '/subs.m3u8',
          utf8.encode('#EXTM3U\n#EXTINF:1,\n0.vtt\n#EXTINF:1,\n1.vtt\n'),
        )
        ..bytes(
          '/0.vtt',
          utf8.encode('WEBVTT\n\n00:00.000 --> 00:01.000\nhi\n'),
        )
        ..bytes('/1.vtt', utf8.encode('[playlist]\nFile1=http://x/\n'));
      final master = await player.text(openCrafted('/master.m3u8').url);
      final subs = await player.text(proxiedUris(master).first);
      final [vtt, bad] = proxiedUris(subs);
      expect(vtt.pathSegments.last, 'sub.vtt');
      final (status, headers, body) = await player.get(vtt);
      expect(status, 200);
      expect(headers['content-type'], startsWith('text/vtt'));
      expect(utf8.decode(body), startsWith('WEBVTT'));
      expect((await player.get(bad)).$1, 415);
    });

    test('gzip 由客户端解压后照常返回（不带长度）；其他编码 502', () async {
      final mp4 = fakeMp4();
      up
        ..routes['/gz.mp4'] = (req) {
          req.response.headers
            ..set('content-type', 'video/mp4')
            ..set('content-encoding', 'gzip');
          req.response.add(gzip.encode(mp4));
          return req.response.close();
        }
        ..bytes('/br.mp4', mp4, headers: {'content-encoding': 'br'});
      final (s1, h1, b1) = await player.get(openCrafted('/gz.mp4').url);
      expect(s1, 200);
      expect(b1, mp4);
      expect(h1['content-length'], isNull);
      expect((await player.get(openCrafted('/br.mp4').url)).$1, 502);
    });

    test('密钥或填充错误的 AES-128 分片 502；密文“解密”成文本则 415', () async {
      up
        ..bytes(
          '/enc.m3u8',
          utf8.encode(
            '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="k.bin",IV=0x01\n'
            '#EXTINF:1,\nbad.ts\n#EXTINF:1,\nshort.ts\n',
          ),
        )
        ..bytes('/k.bin', utf8.encode('0123456789abcdef'))
        ..bytes('/bad.ts', List.filled(64, 7))
        ..bytes('/short.ts', List.filled(10, 7));
      final uris = proxiedUris(await player.text(openCrafted('/enc.m3u8').url));
      expect([for (final u in uris) (await player.get(u)).$1], [502, 502]);
    });

    test('AES-128 与 EXT-X-BYTERANGE 同时出现：不支持（403）', () async {
      up.bytes(
        '/br.m3u8',
        utf8.encode(
          '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="k.bin"\n'
          '#EXT-X-BYTERANGE:100@0\n#EXTINF:1,\nall.ts\n',
        ),
      );
      final uris = proxiedUris(await player.text(openCrafted('/br.m3u8').url));
      expect((await player.get(uris.single)).$1, 403);
    });

    test('播放器断开后，上游请求最晚在 prepareTimeout 时取消', () async {
      final released = Completer<void>();
      up.routes['/hang.mp4'] = (req) async {
        // 只发响应头，迟迟不发响应体。
        req.response.headers.set('content-type', 'video/mp4');
        await req.response.flush();
        await released.future;
        await req.response.close();
      };
      final session = openCrafted('/hang.mp4');
      final raw = HttpClient();
      final req = await raw.getUrl(session.url);
      final pending = req.close().then((_) {}, onError: (Object _) {});
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(session.inFlight, 1);
      req.abort();
      await pending;
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (session.inFlight > 0 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(session.inFlight, 0);
      released.complete();
      raw.close(force: true);
    });

    test('关闭会话取消进行中的请求', () async {
      final released = Completer<void>();
      up.routes['/hang2.mp4'] = (req) async {
        await req.response.flush();
        await released.future;
        await req.response.close();
      };
      final session = openCrafted('/hang2.mp4');
      final result = player.get(session.url);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      session.close();
      final (status, _, _) = await result.timeout(const Duration(seconds: 2));
      expect(status, anyOf(404, 502));
      expect(session.inFlight, 0);
      released.complete();
    });
  });

  test('非 http(s) 地址得到总是 403 的代理地址', () async {
    final session = open('file:///etc/passwd');
    expect((await player.get(session.url)).$1, 403);
  });

  test('上游错误状态原样返回；白名单外的根地址为 403', () async {
    expect(
      (await player.get(open('http://video.example.com/status/404').url)).$1,
      404,
    );
    final outside = open('http://outside.example.net/a.mp4');
    expect((await player.get(outside.url)).$1, 403);
    expect(outside.lastFailure?.kind, NetworkErrorKind.hostNotAllowed);
    expect(
      server.requests.where((r) => r.host == 'outside.example.net'),
      isEmpty,
    );
  });

  test('未知令牌 / 编号、关闭后的会话返回 404；只接受 GET / HEAD', () async {
    final session = open('http://video.example.com/video/media/clip.mp4');
    final seg = session.url.pathSegments;
    final base = session.url;
    expect(
      (await player.get(base.replace(pathSegments: ['x' * 32, ...seg.skip(1)])))
          .$1,
      404,
    );
    expect(
      (await player.get(base.replace(pathSegments: [seg[0], '7', seg[2]]))).$1,
      404,
    );
    expect((await player.get(base, method: 'POST')).$1, 405);
    session.close();
    expect((await player.get(base)).$1, 404);
  });
}
