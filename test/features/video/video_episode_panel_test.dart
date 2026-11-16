import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/features/video/player/video_episode_panel.dart';
import 'package:tsumugi/features/video/player/video_playlist.dart';
import 'package:tsumugi/sources/model/common.dart';

void main() {
  final playlist = VideoPlaylist(
    const Detail(
      id: 'x',
      title: 't',
      groups: [
        UnitGroup(
          name: '线路 A',
          units: [
            Unit(id: 'a1', title: '第 1 集'),
            Unit(id: 'a2', title: '第 2 集'),
          ],
        ),
        UnitGroup(
          name: '线路 B',
          units: [Unit(id: 'b1', title: '第 1 集')],
        ),
      ],
    ),
  );

  Future<(List<EpisodeLocation>, List<int>)> pump(
    WidgetTester tester,
    VideoPlaylist playlist,
    EpisodeLocation? current, {
    Set<String> read = const {},
  }) async {
    final opened = <EpisodeLocation>[];
    final lines = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VideoEpisodePanel(
            playlist: playlist,
            current: current,
            readUnitIds: read,
            onOpen: opened.add,
            onSwitchLine: lines.add,
          ),
        ),
      ),
    );
    return (opened, lines);
  }

  testWidgets('列出当前线路的剧集，标出正在播放与已看', (tester) async {
    await pump(tester, playlist, (line: 0, index: 0), read: {'a2'});
    expect(find.text('选集（2）'), findsOneWidget);
    expect(find.text('线路 A'), findsOneWidget);
    expect(find.text('线路 B'), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    expect(find.byIcon(Icons.check), findsOneWidget);
  });

  testWidgets('点击剧集、上一集 / 下一集、切换线路', (tester) async {
    final (opened, lines) = await pump(tester, playlist, (line: 0, index: 0));
    await tester.tap(find.text('第 2 集'));
    await tester.tap(find.byTooltip('下一集'));
    // 第一集没有上一集（按钮不可用）；正在播放的剧集与当前线路不可点。
    await tester.tap(find.byTooltip('上一集'));
    await tester.tap(find.text('第 1 集'));
    await tester.tap(find.text('线路 A'));
    await tester.tap(find.text('线路 B'));
    expect(opened, [(line: 0, index: 1), (line: 0, index: 1)]);
    expect(lines, [1]);
  });

  testWidgets('第二条线路：列出该线路的剧集', (tester) async {
    await pump(tester, playlist, (line: 1, index: 0));
    expect(find.text('选集（1）'), findsOneWidget);
    expect(find.text('第 2 集'), findsNothing);
  });

  testWidgets('单条线路时不显示线路选择', (tester) async {
    final single = VideoPlaylist(
      const Detail(
        id: 'x',
        title: 't',
        units: [Unit(id: '1', title: 'only')],
      ),
    );
    await pump(tester, single, null);
    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.text('only'), findsOneWidget);
  });
}
