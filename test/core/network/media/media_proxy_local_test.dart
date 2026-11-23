import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/network/media/media_proxy.dart';

/// 本地来源会话（architecture §4.5.1「离线回放」）：只按编号返回登记的文件，不接受路径、不发上游请求。
void main() {
  late MediaProxy proxy;
  late Directory dir;
  final http = HttpClient();

  Future<(int, Map<String, String>, Uint8List)> get(
    Uri url, {
    String method = 'GET',
    Map<String, String> headers = const {},
  }) async {
    final req = await http.openUrl(method, url);
    headers.forEach(req.headers.set);
    final res = await req.close();
    final body = await res.fold<BytesBuilder>(
      BytesBuilder(),
      (b, c) => b..add(c),
    );
    final h = <String, String>{};
    res.headers.forEach((k, v) => h[k] = v.join(', '));
    return (res.statusCode, h, body.takeBytes());
  }

  /// MPEG-TS 同步字节开头的假分片。
  Uint8List ts(int n, [int fill = 1]) => Uint8List.fromList([
    for (var i = 0; i < n; i++) i % 188 == 0 ? 0x47 : fill,
  ]);

  File write(String name, List<int> bytes) => File('${dir.path}/$name')
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(bytes);

  setUp(() async {
    proxy = await MediaProxy.start();
    dir = await Directory.systemTemp.createTemp('tsumugi_local_');
  });

  tearDown(() async {
    await proxy.close();
    await dir.delete(recursive: true);
  });

  tearDownAll(() => http.close(force: true));

  LocalMediaSession openHls() {
    final seg0 = write('v/00001.ts', ts(1880));
    final seg1 = write('v/00002.ts', ts(940, 2));
    final vtt = write(
      's1/00001.vtt',
      utf8.encode('WEBVTT\n\n00:00.000 --> 00:01.000\nhi\n'),
    );
    return proxy.openLocal(
      root: 'index.m3u8',
      playlists: {
        'index.m3u8':
            '#EXTM3U\n'
            '#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="中文",URI="s1/index.m3u8"\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=1,SUBTITLES="subs"\n'
            'v/index.m3u8\n',
        'v/index.m3u8':
            '#EXTM3U\n#EXT-X-TARGETDURATION:2\n'
            '#EXTINF:2,\nv/00001.ts\n#EXTINF:2,\nv/00002.ts\n'
            // 未登记的名称、绝对地址、目录穿越都不会得到可用的编号。
            '#EXTINF:2,\nv/00003.ts\n#EXTINF:2,\nhttp://example.com/x.ts\n'
            '#EXTINF:2,\n../../secret.ts\n'
            '#EXT-X-ENDLIST\n',
        's1/index.m3u8': '#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:2,\ns1/00001.vtt\n#EXT-X-ENDLIST\n',
      },
      files: {
        'v/00001.ts': LocalMediaFile(
          seg0,
          LocalMediaKind.media,
          extension: 'ts',
        ),
        'v/00002.ts': LocalMediaFile(
          seg1,
          LocalMediaKind.media,
          extension: 'ts',
        ),
        's1/00001.vtt': LocalMediaFile(vtt, LocalMediaKind.subtitle),
      },
    );
  }

  List<Uri> uris(String playlist) => [
    for (final line in const LineSplitter().convert(playlist))
      if (line.isNotEmpty && !line.startsWith('#'))
        Uri.parse(line)
      else
        for (final m in RegExp(r'URI="([^"]*)"').allMatches(line))
          Uri.parse(m[1]!),
  ];

  test('playlists are rewritten to proxy addresses by index', () async {
    final session = openHls();
    final (status, headers, body) = await get(session.url);
    expect(status, 200);
    expect(headers['content-type'], contains('mpegurl'));
    final master = utf8.decode(body);
    // 字幕轨不交给播放器（#84）：记在会话上，由字幕层经本会话自己取。
    expect(master, isNot(contains('EXT-X-MEDIA')));
    final [variant] = uris(master);
    final track = session.subtitleTracks.single;
    expect(track.name, '中文');
    final sub = Uri.parse(track.url);
    expect(sub.pathSegments.last, 'index.m3u8');
    final media = utf8.decode((await get(variant)).$3);
    final segs = uris(media);
    expect(segs, hasLength(5));
    expect(
      [for (final u in segs) u.pathSegments.last],
      [
        'media.ts', 'media.ts', 'media.bin', 'media.bin', 'media.bin', //
      ],
    );
    // 只有登记的两个分片有编号；其余为 `x`（总是 404）。
    expect(
      [for (final u in segs) u.pathSegments[1]].where((s) => s == 'x'),
      hasLength(3),
    );
    for (final u in segs.skip(2)) {
      expect((await get(u)).$1, 404);
    }
    final (s0, h0, b0) = await get(segs[0]);
    expect(s0, 200);
    expect(h0['content-type'], 'application/octet-stream');
    expect(b0, hasLength(1880));
    // 字幕分片。
    final subPlaylist = utf8.decode((await get(sub)).$3);
    final (s2, h2, b2) = await get(uris(subPlaylist).single);
    expect(s2, 200);
    expect(h2['content-type'], contains('text/vtt'));
    expect(utf8.decode(b2), startsWith('WEBVTT'));
    expect(session.hadFileError, isFalse);
  });

  test('Range and HEAD', () async {
    final session = openHls();
    final media = utf8.decode(
      (await get(uris(utf8.decode((await get(session.url)).$3)).last)).$3,
    );
    final seg = uris(media).first;
    final (s, h, b) = await get(seg, headers: {'range': 'bytes=100-199'});
    expect(s, 206);
    expect(h['content-range'], 'bytes 100-199/1880');
    expect(b, hasLength(100));
    expect((await get(seg, headers: {'range': 'bytes=5000-'})).$1, 416);
    final (hs, hh, hb) = await get(seg, method: 'HEAD');
    expect(hs, 200);
    expect(hh['content-length'], '1880');
    expect(hb, isEmpty);
    expect((await get(seg, method: 'POST')).$1, 405);
  });

  test('requests never resolve paths: only token + index', () async {
    final session = openHls();
    final token = session.url.pathSegments.first;
    for (final path in [
      '/$token/99/media.ts',
      '/$token/-1/media.ts',
      '/$token/v/00001.ts',
      '/$token/0/../../v/00001.ts',
      '/$token/0',
      '/other/0/index.m3u8',
    ]) {
      final url = proxy.origin.replace(path: path);
      expect((await get(url)).$1, 404, reason: path);
    }
    // 文件名部分不参与查找：编号 0（主播放列表）配任意文件名仍是主播放列表。
    final any = proxy.origin.replace(pathSegments: [token, '0', 'passwd']);
    expect(utf8.decode((await get(any)).$3), startsWith('#EXTM3U'));
  });

  test('unrecognised or missing files are rejected and flagged', () async {
    final good = write('media.bin', ts(1880));
    final session = proxy.openLocal(
      root: 'media.bin',
      files: {'media.bin': LocalMediaFile(good, LocalMediaKind.media)},
    );
    expect((await get(session.url)).$1, 200);
    expect(session.hadFileError, isFalse);
    // 被替换成 HTML：不交给播放器。
    good.writeAsStringSync('<html>not media</html>');
    expect((await get(session.url)).$1, 415);
    expect(session.hadFileError, isTrue);

    final missing = proxy.openLocal(
      root: 'media.bin',
      files: {
        'media.bin': LocalMediaFile(
          File('${dir.path}/gone.bin'),
          LocalMediaKind.media,
        ),
      },
    );
    expect((await get(missing.url)).$1, 404);
    expect(missing.hadFileError, isTrue);
  });

  test('closed sessions return 404', () async {
    final session = openHls();
    expect((await get(session.url)).$1, 200);
    session.close();
    expect((await get(session.url)).$1, 404);
  });

  test('root must be registered', () {
    expect(() => proxy.openLocal(root: 'x'), throwsArgumentError);
  });
}
