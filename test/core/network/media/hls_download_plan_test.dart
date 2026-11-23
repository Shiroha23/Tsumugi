import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/network/media/hls_download_plan.dart';

final _base = Uri.parse('https://video.example.com/show/1/master.m3u8?sig=abc');

void main() {
  group('selectHlsDownload', () {
    test('picks the highest BANDWIDTH, default audio and all subtitles', () {
      final s = selectHlsDownload('''
#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="日本語",LANGUAGE="ja",URI="a/ja.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",DEFAULT=YES,URI="a/en.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="other",NAME="x",DEFAULT=YES,URI="a/x.m3u8"
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="中文",LANGUAGE="zh",URI="s/zh.m3u8"
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",LANGUAGE="en",URI="s/en.m3u8"
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="no uri"
#EXT-X-STREAM-INF:BANDWIDTH=500000,RESOLUTION=640x360,AUDIO="aud",SUBTITLES="subs"
low.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2000000,AVERAGE-BANDWIDTH=1500000,RESOLUTION=1280x720,CODECS="avc1.4d401f,mp4a.40.2",AUDIO="aud",SUBTITLES="subs"
high.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720
same.m3u8
''', _base)!;
      expect(
        s.variant.uri.toString(),
        'https://video.example.com/show/1/high.m3u8',
      );
      expect(s.variant.bandwidth, 2000000);
      expect(s.variant.resolution, '1280x720');
      expect(s.variant.codecs, 'avc1.4d401f,mp4a.40.2');
      expect(s.audio?.name, 'English');
      expect(s.audio?.uri?.path, '/show/1/a/en.m3u8');
      expect([for (final t in s.subtitles) t.name], ['中文', 'English']);
    });

    test('first audio when none is default; muxed audio is not separate', () {
      final s = selectHlsDownload('''
#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="a1",URI="a1.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="a2",URI="a2.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="muxed",NAME="m",DEFAULT=YES
#EXT-X-STREAM-INF:BANDWIDTH=1,AUDIO="aud"
v1.m3u8
''', _base)!;
      expect(s.audio?.name, 'a1');
      final muxed = selectHlsDownload('''
#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="muxed",NAME="m",DEFAULT=YES
#EXT-X-STREAM-INF:BANDWIDTH=1,AUDIO="muxed"
v1.m3u8
''', _base)!;
      expect(muxed.audio, isNull);
      expect(muxed.subtitles, isEmpty);
    });

    test('media playlist is not a master', () {
      expect(
        selectHlsDownload(
          '#EXTM3U\n#EXTINF:2,\nseg.ts\n#EXT-X-ENDLIST\n',
          _base,
        ),
        isNull,
      );
    });
  });

  group('parseHlsMediaPlaylist', () {
    test('segments, durations, AES-128, map, byte ranges, discontinuity', () {
      final p = parseHlsMediaPlaylist('''
#EXTM3U
#EXT-X-TARGETDURATION:4
#EXT-X-MEDIA-SEQUENCE:5
#EXT-X-MAP:URI="init.mp4"
#EXTINF:4.004,
seg5.m4s?token=1
#EXT-X-DISCONTINUITY
#EXT-X-BYTERANGE:1000@0
#EXTINF:3.5,title
all.m4s
#EXT-X-BYTERANGE:500
#EXTINF:2,
all.m4s
#EXT-X-KEY:METHOD=AES-128,URI="key.bin"
#EXTINF:2,
enc.ts
#EXT-X-KEY:METHOD=NONE
#EXTINF:1,
https://cdn.example.com/last.ts
#EXT-X-DATERANGE:ID="ad",X-ASSET-LIST="https://ads.example.com/x"
#EXT-X-ENDLIST
''', _base);
      expect(p.mediaSequence, 5);
      expect(p.segmentCount, 5);
      final items = p.items;
      expect(items.first.kind, HlsItemKind.init);
      expect(items.first.uri.path, '/show/1/init.mp4');
      expect(items[1].duration, 4.004);
      expect(items[1].uri.query, 'token=1');
      expect(items[2].discontinuity, isTrue);
      expect(items[2].range, (0, 1000));
      expect(items[3].range, (1000, 500));
      expect(items[4].aes?.keyUri?.path, '/show/1/key.bin');
      // IV 缺省时为媒体序号（第 4 个分片：5 + 3 = 8）。
      expect(items[4].aes?.iv.last, 8);
      expect(items[5].aes, isNull);
      expect(items[5].uri.host, 'cdn.example.com');
    });

    test('live playlists cannot be downloaded', () {
      expect(
        () => parseHlsMediaPlaylist('#EXTM3U\n#EXTINF:2,\nseg.ts\n', _base),
        throwsA(isA<HlsUnsupportedException>()),
      );
    });

    test('SAMPLE-AES and other methods are unsupported', () {
      for (final method in ['SAMPLE-AES', 'SAMPLE-AES-CTR', 'X-CUSTOM']) {
        expect(
          () => parseHlsMediaPlaylist(
            '#EXTM3U\n#EXT-X-KEY:METHOD=$method,URI="k"\n#EXTINF:2,\nseg.ts\n#EXT-X-ENDLIST\n',
            _base,
          ),
          throwsA(isA<HlsUnsupportedException>()),
          reason: method,
        );
      }
    });

    test('AES-128 with byte ranges or missing IV on map is unsupported', () {
      expect(
        () => parseHlsMediaPlaylist(
          '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="k"\n#EXT-X-BYTERANGE:10@0\n#EXTINF:2,\nseg.ts\n#EXT-X-ENDLIST\n',
          _base,
        ),
        throwsA(isA<HlsUnsupportedException>()),
      );
      expect(
        () => parseHlsMediaPlaylist(
          '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="k"\n#EXT-X-MAP:URI="init.mp4"\n#EXTINF:2,\nseg.ts\n#EXT-X-ENDLIST\n',
          _base,
        ),
        throwsA(isA<HlsUnsupportedException>()),
      );
    });

    test('non-http segment addresses are unsupported', () {
      expect(
        () => parseHlsMediaPlaylist(
          '#EXTM3U\n#EXTINF:2,\nfile:///etc/passwd\n#EXT-X-ENDLIST\n',
          _base,
        ),
        throwsA(isA<HlsUnsupportedException>()),
      );
    });

    test('format errors', () {
      expect(
        () => parseHlsMediaPlaylist('not a playlist', _base),
        throwsFormatException,
      );
      expect(
        () => parseHlsMediaPlaylist('#EXTM3U\nseg.ts\n#EXT-X-ENDLIST\n', _base),
        throwsFormatException,
      );
      expect(
        () => parseHlsMediaPlaylist('#EXTM3U\n#EXT-X-ENDLIST\n', _base),
        throwsFormatException,
      );
    });
  });

  test('strippedHlsUrl drops query and fragment', () {
    expect(
      strippedHlsUrl(
        Uri.parse('https://cdn.example.com:8443/a/b.ts?sig=1&t=2#x'),
      ),
      'https://cdn.example.com:8443/a/b.ts',
    );
  });

  test('parseHlsAttributes handles quoted commas', () {
    expect(parseHlsAttributes('BANDWIDTH=1,CODECS="a,b",NAME="x=y"'), {
      'BANDWIDTH': '1',
      'CODECS': 'a,b',
      'NAME': 'x=y',
    });
  });
}
