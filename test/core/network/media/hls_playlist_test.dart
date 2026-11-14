import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/network/media/hls_playlist.dart';

void main() {
  final base = Uri.parse('http://video.example.com/show/1/hls/index.m3u8');
  final seen = <(Uri?, HlsUriKind)>[];
  final aesSeen = <HlsAes128?>[];
  String map(Uri? uri, HlsUriKind kind, [HlsAes128? aes]) {
    seen.add((uri, kind));
    aesSeen.add(aes);
    return 'http://127.0.0.1:1/t/${seen.length - 1}';
  }

  setUp(() {
    seen.clear();
    aesSeen.clear();
  });

  test('未加密：分片、初始化分片与字节区间都被改写并基于最终地址解析', () {
    const text = '''
#EXTM3U
#EXT-X-VERSION:7
#EXT-X-TARGETDURATION:2
#EXT-X-MAP:URI="/init.mp4",BYTERANGE="100@0"
#EXTINF:2.0,
seg0.ts
#EXT-X-BYTERANGE:500@100
#EXTINF:2.0,
https://cdn.example.com/seg1.ts?x=1
#EXT-X-ENDLIST
''';
    final out = rewriteHlsPlaylist(text, base: base, map: map);
    expect(seen, [
      (Uri.parse('http://video.example.com/init.mp4'), HlsUriKind.media),
      (
        Uri.parse('http://video.example.com/show/1/hls/seg0.ts'),
        HlsUriKind.media,
      ),
      (Uri.parse('https://cdn.example.com/seg1.ts?x=1'), HlsUriKind.media),
    ]);
    expect(aesSeen, everyElement(isNull));
    expect(
      out,
      contains('#EXT-X-MAP:URI="http://127.0.0.1:1/t/0",BYTERANGE="100@0"'),
    );
    expect(out, contains('#EXT-X-BYTERANGE:500@100'));
    expect(out, isNot(contains('example.com')));
  });

  test('AES-128：密钥行不输出，分片带上密钥地址与 IV（显式或媒体序号）', () {
    const text = '''
#EXTM3U
#EXT-X-MEDIA-SEQUENCE:7
#EXT-X-KEY:METHOD=AES-128,URI="k1.bin"
#EXTINF:2,
a.ts
#EXTINF:2,
b.ts
#EXT-X-KEY:METHOD=AES-128,URI="/k2.bin",IV=0x0102
#EXT-X-MAP:URI="init.mp4"
#EXTINF:2,
c.ts
#EXT-X-KEY:METHOD=NONE
#EXTINF:2,
d.ts
''';
    final out = rewriteHlsPlaylist(text, base: base, map: map);
    expect(out, isNot(contains('AES-128')));
    expect(out, contains('#EXT-X-KEY:METHOD=NONE'));
    expect(out, isNot(contains('example.com')));
    final k1 = Uri.parse('http://video.example.com/show/1/hls/k1.bin');
    final k2 = Uri.parse('http://video.example.com/k2.bin');
    List<int> iv(int last, [int prev = 0]) => [
      ...List.filled(14, 0),
      prev,
      last,
    ];
    expect(seen.map((e) => e.$1?.pathSegments.last), [
      'a.ts',
      'b.ts',
      'init.mp4',
      'c.ts',
      'd.ts',
    ]);
    expect(aesSeen[0], HlsAes128(k1, Uint8List.fromList(iv(7))));
    expect(aesSeen[1], HlsAes128(k1, Uint8List.fromList(iv(8))));
    expect(aesSeen[2], HlsAes128(k2, Uint8List.fromList(iv(2, 1))));
    expect(aesSeen[3], HlsAes128(k2, Uint8List.fromList(iv(2, 1))));
    expect(aesSeen[4], isNull);
  });

  test('AES-128 与字节区间、无效 IV：分片不支持（null 地址）', () {
    rewriteHlsPlaylist(
      '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="k.bin"\n'
      '#EXT-X-BYTERANGE:10@0\n#EXTINF:1,\na.ts\n'
      '#EXT-X-KEY:METHOD=AES-128,URI="k.bin",IV=0xZZ\n#EXTINF:1,\nb.ts\n'
      '#EXT-X-KEY:METHOD=AES-128,URI="k.bin"\n#EXT-X-MAP:URI="i.mp4"\n',
      base: base,
      map: map,
    );
    expect(seen, [(null, HlsUriKind.media), (null, HlsUriKind.media)]);
  });

  test('SAMPLE-AES 等其他加密方式：密钥地址照常改写，由播放器经代理取得', () {
    final out = rewriteHlsPlaylist(
      '#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI="k.bin"\n#EXTINF:1,\na.ts\n',
      base: base,
      map: map,
    );
    expect(seen.first.$2, HlsUriKind.key);
    expect(aesSeen, everyElement(isNull));
    expect(
      out,
      contains('#EXT-X-KEY:METHOD=SAMPLE-AES,URI="http://127.0.0.1:1/t/0"'),
    );
  });

  test('字幕 EXT-X-MEDIA 标记为字幕播放列表', () {
    rewriteHlsPlaylist(
      '#EXTM3U\n'
      '#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="s",NAME="ja",URI="s.m3u8"\n'
      '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="ja",URI="a.m3u8"\n',
      base: base,
      map: map,
    );
    expect(seen.map((e) => e.$2), [
      HlsUriKind.subtitlePlaylist,
      HlsUriKind.playlist,
    ]);
  });

  test('主播放列表：变体与 EXT-X-MEDIA 被标记为子播放列表', () {
    const text =
        '#EXTM3U\r\n'
        '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="ja",URI="audio/ja.m3u8"\r\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=1000,AUDIO="a"\r\n'
        'low/index.m3u8\r\n'
        '#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=100,URI="iframe.m3u8"\r\n';
    final out = rewriteHlsPlaylist(text, base: base, map: map);
    expect(seen.map((e) => e.$2), [
      HlsUriKind.playlist,
      HlsUriKind.playlist,
      HlsUriKind.playlist,
    ]);
    expect(
      seen[1].$1,
      Uri.parse('http://video.example.com/show/1/hls/low/index.m3u8'),
    );
    expect(out, isNot(contains('example.com')));
    expect(out, isNot(contains('\r')));
  });

  test('只有 STREAM-INF 之后的第一行是子播放列表', () {
    rewriteHlsPlaylist(
      '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\n\na.m3u8\n#EXTINF:1,\nb.ts\n',
      base: base,
      map: map,
    );
    expect(seen.map((e) => e.$2), [HlsUriKind.playlist, HlsUriKind.media]);
  });

  test('可能带其他地址的标签与普通注释被删除', () {
    const text = '''
#EXTM3U
# comment with http://evil.example.net/
#EXT-X-SESSION-DATA:DATA-ID="x",URI="http://evil.example.net/data.json"
#EXT-X-CONTENT-STEERING:SERVER-URI="http://evil.example.net/steer"
#EXT-X-DATERANGE:ID="ad",START-DATE="2026-01-01T00:00:00Z",X-ASSET-URI="http://evil.example.net/ad.m3u8"
#EXT-X-DATERANGE:ID="ad2",START-DATE="2026-01-01T00:00:00Z",X-ASSET-LIST="http://evil.example.net/ads.json"
#EXT-X-DEFINE:NAME="host",VALUE="http://evil.example.net"
#EXT-X-CUE-OUT:30
#EXT-X-PRELOAD-HINT:TYPE=PART,URI="part.mp4"
#EXT-X-FOO:uri=http://evil.example.net/
#EXTINF:1,
a.ts
''';
    final out = rewriteHlsPlaylist(text, base: base, map: map);
    expect(out, isNot(contains('evil')));
    expect(out, isNot(contains('comment')));
    expect(seen.map((e) => e.$1?.path), [
      '/show/1/hls/part.mp4',
      '/show/1/hls/a.ts',
    ]);
  });

  test('SERVER-URI 不被当作 URI 属性改写', () {
    final out = rewriteHlsPlaylist(
      '#EXTM3U\n#EXT-X-UNKNOWN:SERVER-URI="http://evil.example.net/",URI="x"\n',
      base: base,
      map: map,
    );
    expect(out.trim(), '#EXTM3U');
  });

  test('无法解析的地址以 null 交给 map', () {
    rewriteHlsPlaylist(
      '#EXTM3U\n#EXTINF:1,\nhttp://[::1\n',
      base: base,
      map: map,
    );
    expect(seen.single, (null, HlsUriKind.media));
  });

  test('非 http(s) 地址原样解析后交给 map（由调用方拒绝）', () {
    rewriteHlsPlaylist(
      '#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://k"\n#EXTINF:1,\nfile:///etc/passwd\n',
      base: base,
      map: map,
    );
    expect(seen.map((e) => e.$1?.scheme), ['skd', 'file']);
  });

  test('不是播放列表时抛出 FormatException', () {
    expect(
      () => rewriteHlsPlaylist('<MPD/>', base: base, map: map),
      throwsFormatException,
    );
    expect(
      rewriteHlsPlaylist('﻿\n#EXTM3U\n', base: base, map: map),
      '#EXTM3U\n',
    );
  });

  test('looksLikeHlsPlaylist', () {
    expect(looksLikeHlsPlaylist(utf8.encode('#EXTM3U\n')), isTrue);
    expect(
      looksLikeHlsPlaylist([0xEF, 0xBB, 0xBF, ...utf8.encode(' \n#EXTM3U')]),
      isTrue,
    );
    expect(looksLikeHlsPlaylist(utf8.encode('#EXTM3')), isFalse);
    expect(looksLikeHlsPlaylist([0x47, 0x40, 0x11]), isFalse);
  });
}
