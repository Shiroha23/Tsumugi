import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/shared/download/video_manifest.dart';

final _key = 'a' * 64;

VideoManifest _hls() => VideoManifest.hls(
  sourceKey: _key,
  label: '720p',
  bandwidth: 148896,
  resolution: '320x180',
  codecs: 'avc1.42c00c,mp4a.40.2',
  tracks: [
    VideoTrack(
      type: VideoTrackType.video,
      dir: 'v',
      mediaSequence: 3,
      items: [
        const VideoItem(init: true, file: 'v/00001.mp4'),
        const VideoItem(init: false, duration: 2.5, file: 'v/00002.mp4'),
        const VideoItem(
          init: false,
          duration: 2,
          discontinuity: true,
          file: 'v/00003.mp4',
        ),
      ],
    ),
    const VideoTrack(
      type: VideoTrackType.audio,
      dir: 'a',
      mediaSequence: 0,
      items: [VideoItem(init: false, duration: 4, file: 'a/00001.aac')],
    ),
    const VideoTrack(
      type: VideoTrackType.subtitles,
      dir: 's1',
      mediaSequence: 0,
      name: 'HLS "Chinese"\n#EXT-X-KEY',
      language: 'zh',
      items: [VideoItem(init: false, duration: 4, file: 's1/00001.vtt')],
    ),
  ],
  subtitles: const [
    VideoSubtitleEntry(file: 'sub-01.srt', lang: '简体中文', format: 'srt'),
  ],
);

Map<String, Object?> _json(VideoManifest m) =>
    jsonDecode(m.encode()) as Map<String, Object?>;

void main() {
  test('round trip', () {
    final m = VideoManifest.decode(_hls().encode());
    expect(m.isHls, isTrue);
    expect(m.complete, isTrue);
    expect(m.label, '720p');
    expect(m.tracks.map((t) => t.dir), ['v', 'a', 's1']);
    expect(m.tracks.first.items[1].duration, 2.5);
    expect(m.tracks.first.items[2].discontinuity, isTrue);
    expect(m.subtitles.single.lang, '简体中文');

    final f = VideoManifest.decode(
      VideoManifest.file(
        sourceKey: _key,
        label: '流 1',
        file: const VideoFileState(length: 10, etag: '"x"'),
      ).encode(),
    );
    expect(f.isHls, isFalse);
    expect(f.file?.validator, '"x"');
  });

  test('rejects file names that are not generated for that position', () {
    void bad(void Function(Map<String, Object?> json) edit, String reason) {
      final json = _json(_hls());
      edit(json);
      expect(
        () => VideoManifest.decode(jsonEncode(json)),
        throwsFormatException,
        reason: reason,
      );
    }

    Map<String, Object?> item(Map<String, Object?> j, int t, int i) =>
        ((((j['tracks'] as List)[t] as Map)['items'] as List)[i]
            as Map<String, Object?>);

    bad((j) => item(j, 0, 1)['f'] = '../00002.mp4', '穿越');
    bad((j) => item(j, 0, 1)['f'] = 'v/../../x.mp4', '穿越');
    bad((j) => item(j, 0, 1)['f'] = 'v/00009.mp4', '序号不符');
    bad((j) => item(j, 0, 1)['f'] = 'a/00002.mp4', '目录不符');
    bad((j) => item(j, 0, 1)['f'] = 'v/00002.html', '扩展名');
    bad((j) => item(j, 2, 0)['f'] = 's1/00001.ts', '字幕轨只能是 vtt');
    bad((j) => item(j, 0, 1)['f'] = r'v\00002.mp4', '分隔符');
    bad((j) => ((j['tracks'] as List)[1] as Map)['dir'] = 'v', '目录重复');
    bad((j) => ((j['tracks'] as List)[2] as Map)['dir'] = 's2', '字幕轨序号');
    bad(
      (j) => ((j['subtitles'] as List)[0] as Map)['file'] = '../sub-01.srt',
      '字幕',
    );
    bad(
      (j) => ((j['subtitles'] as List)[0] as Map)['file'] = 'sub-01.html',
      '字幕',
    );
    bad((j) => j['source'] = 'xyz', 'source');
    bad((j) => j['version'] = 2, 'version');
    bad((j) => (j['tracks'] as List).removeAt(0), '第一个必须是视频');
    bad((j) => item(j, 0, 1).remove('d'), '缺少时长');
  });

  test('incomplete manifest', () {
    final m = _hls().copyWith(
      tracks: [
        _hls().tracks.first.withItems([
          const VideoItem(init: false, duration: 2),
        ]),
      ],
    );
    expect(VideoManifest.decode(m.encode()).complete, isFalse);
  });

  test('local layout: regenerated HLS without keys, names only', () {
    final layout = localVideoLayout(_hls());
    expect(layout.root, 'index.m3u8');
    expect(layout.playlists.keys, {
      'index.m3u8',
      'v/index.m3u8',
      'a/index.m3u8',
      's1/index.m3u8',
    });
    expect(layout.files['v/00002.mp4'], (false, 'mp4'));
    expect(layout.files['s1/00001.vtt'], (true, 'vtt'));
    final master = layout.playlists['index.m3u8']!;
    // 名称中的引号与换行被去掉，不能注入标签。
    expect(master, contains('NAME="HLS Chinese#EXT-X-KEY"'));
    expect(
      master.split('\n').where((l) => l.startsWith('#EXT-X-KEY')),
      isEmpty,
    );
    expect(master, contains('RESOLUTION=320x180'));
    expect(master, contains('AUDIO="aud"'));
    final video = layout.playlists['v/index.m3u8']!;
    expect(video, contains('#EXT-X-MAP:URI="v/00001.mp4"'));
    expect(video, contains('#EXT-X-MEDIA-SEQUENCE:3'));
    expect(video, contains('#EXT-X-DISCONTINUITY\n#EXTINF:2.0,\nv/00003.mp4'));
    expect(video, contains('#EXT-X-TARGETDURATION:3'));
    expect(video, endsWith('#EXT-X-ENDLIST\n'));
    expect(video, isNot(contains('KEY')));

    final single = localVideoLayout(
      VideoManifest.file(
        sourceKey: _key,
        label: 'x',
        file: const VideoFileState(),
      ),
    );
    expect(single.root, videoFileName);
    expect(single.playlists, isEmpty);
  });
}
