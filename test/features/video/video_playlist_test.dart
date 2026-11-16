import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/features/video/player/video_playlist.dart';
import 'package:tsumugi/sources/model/common.dart';
import 'package:tsumugi/sources/model/content.dart';

Unit _u(String id, String title) => Unit(id: id, title: title);

final _twoLines = Detail(
  id: '/show/2',
  title: 't',
  units: [_u('a1', '第 1 集'), _u('a2', '第 2 集'), _u('a3', '第 3 集')],
  groups: [
    UnitGroup(
      name: '线路 A',
      units: [_u('a1', '第 1 集'), _u('a2', '第 2 集'), _u('a3', '第 3 集')],
    ),
    UnitGroup(
      name: '线路 B',
      // 线路 B 缺第 1 集，顺序也不同：按标题对应。
      units: [_u('b3', '第 3 集'), _u('b2', '第 2 集'), _u('bx', '花絮')],
    ),
  ],
);

void main() {
  group('VideoPlaylist', () {
    test('没有 groups 时 units 为唯一一条线路', () {
      final p = VideoPlaylist(
        Detail(id: 'x', title: 't', units: [_u('1', 'a'), _u('2', 'b')]),
      );
      expect(p.lines.single.units.map((u) => u.id), ['1', '2']);
      expect(p.locate('2'), (line: 0, index: 1));
      expect(p.locate('zz'), isNull);
    });

    test('units 中有不在任何线路里的剧集时，units 也作为一条线路', () {
      final p = VideoPlaylist(
        Detail(
          id: 'x',
          title: 't',
          units: [_u('u1', 'a')],
          groups: [
            UnitGroup(name: 'g', units: [_u('g1', 'a')]),
          ],
        ),
      );
      expect(p.lines.map((l) => l.name), ['g', '默认']);
      expect(p.locate('u1'), (line: 1, index: 0));
    });

    test('上一集 / 下一集在当前线路内', () {
      final p = VideoPlaylist(_twoLines);
      final at = p.locate('a2')!;
      expect(p.unitAt(p.neighbor(at, 1)!)!.id, 'a3');
      expect(p.unitAt(p.neighbor(at, -1)!)!.id, 'a1');
      expect(p.neighbor(p.locate('a3')!, 1), isNull);
      expect(p.neighbor(p.locate('a1')!, -1), isNull);
      expect(p.neighbor((line: 1, index: 0), -1), isNull);
    });

    test('同一 id 出现在多条线路时优先当前线路', () {
      final p = VideoPlaylist(
        Detail(
          id: 'x',
          title: 't',
          groups: [
            UnitGroup(name: 'A', units: [_u('same', '1')]),
            UnitGroup(name: 'B', units: [_u('x', '0'), _u('same', '1')]),
          ],
        ),
      );
      expect(p.locate('same'), (line: 0, index: 0));
      expect(p.locate('same', preferLine: 1), (line: 1, index: 1));
      expect(p.locate('same', preferLine: 9), (line: 0, index: 0));
    });

    test('切换线路：先按标题，再按下标，最后第一集', () {
      final p = VideoPlaylist(_twoLines);
      expect(p.switchLine(p.locate('a3')!, 1), (line: 1, index: 0));
      expect(p.switchLine(p.locate('a2')!, 1), (line: 1, index: 1));
      // 第 1 集在线路 B 中没有：同一下标。
      expect(p.switchLine(p.locate('a1')!, 1), (line: 1, index: 0));
      expect(p.switchLine(p.locate('a1')!, 5), isNull);

      final short = VideoPlaylist(
        Detail(
          id: 'x',
          title: 't',
          groups: [
            UnitGroup(name: 'A', units: [_u('1', 'x'), _u('2', 'y')]),
            UnitGroup(name: 'B', units: [_u('3', 'z')]),
            const UnitGroup(name: 'C'),
          ],
        ),
      );
      expect(short.switchLine((line: 0, index: 1), 1), (line: 1, index: 0));
      expect(short.switchLine((line: 0, index: 1), 2), isNull);
    });
  });

  group('清晰度', () {
    const streams = [
      StreamRef(url: 'a.m3u8', type: StreamType.hls, quality: '1080p'),
      StreamRef(url: 'b.mpd', type: StreamType.dash, quality: '4K'),
      StreamRef(url: 'c.mp4', quality: ' '),
    ];
    final playable = playableStreams(const VideoContent(streams: streams));

    test('跳过 DASH；无标签时显示“流 n”', () {
      expect(playable.map((s) => s.url), ['a.m3u8', 'c.mp4']);
      expect(streamLabel(playable, 0), '1080p');
      expect(streamLabel(playable, 1), '流 2');
    });

    test('换集时优先沿用同名清晰度', () {
      expect(pickStream(playable, '流 2'), 1);
      expect(pickStream(playable, '720p'), 0);
      expect(pickStream(playable, null), 0);
      expect(pickStream(const [], '1080p'), -1);
    });
  });

  test('isFinished：播放完成或到达时长的 97%', () {
    const d = Duration(minutes: 10);
    expect(isFinished(Duration.zero, d, completed: true), isTrue);
    expect(
      isFinished(const Duration(minutes: 9, seconds: 42), d, completed: false),
      isTrue,
    );
    expect(
      isFinished(const Duration(minutes: 9), d, completed: false),
      isFalse,
    );
    expect(
      isFinished(const Duration(seconds: 5), Duration.zero, completed: false),
      isFalse,
      reason: '时长未知',
    );
  });

  test('formatPlaybackPosition', () {
    expect(formatPlaybackPosition(const Duration(seconds: 5)), '0:05');
    expect(
      formatPlaybackPosition(const Duration(minutes: 12, seconds: 3)),
      '12:03',
    );
    expect(
      formatPlaybackPosition(const Duration(hours: 1, minutes: 2, seconds: 3)),
      '1:02:03',
    );
  });
}
