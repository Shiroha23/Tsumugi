import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/features/video/player/video_playback.dart';
import 'package:tsumugi/features/video/player/video_subtitles.dart';
import 'package:tsumugi/shared/video/subtitle_providers.dart';
import 'package:tsumugi/sources/model/content.dart';

const _subs = [
  SubtitleRef(url: '/zh.srt', lang: '简体中文'),
  SubtitleRef(url: '/en.vtt', lang: 'English'),
  SubtitleRef(url: '/x.ass'),
];

const _embedded = [
  EmbeddedSubtitle('1', title: 'HLS Chinese', language: 'zh'),
  EmbeddedSubtitle('2', language: 'ja'),
  EmbeddedSubtitle('3'),
];

SubtitleDocument _doc() => SubtitleDocument(SubtitleFormat.srt, const [
  SubtitleCue(Duration(seconds: 1), Duration(seconds: 2), '第一条'),
  SubtitleCue(Duration(seconds: 3), Duration(seconds: 4), '第二条'),
]);

void main() {
  group('标签', () {
    test('外挂字幕：lang，缺省为“字幕 n”', () {
      expect(externalSubtitleLabel(_subs, 0), '简体中文');
      expect(externalSubtitleLabel(_subs, 2), '字幕 3');
      expect(
        externalSubtitleLabel(const [SubtitleRef(url: '/a', lang: '  ')], 0),
        '字幕 1',
      );
    });

    test('内嵌轨：名称 → 语言 → “内嵌字幕 n”', () {
      expect(embeddedSubtitleLabel(_embedded, 0), 'HLS Chinese');
      expect(embeddedSubtitleLabel(_embedded, 1), 'ja');
      expect(embeddedSubtitleLabel(_embedded, 2), '内嵌字幕 3');
    });

    test('按标签、名称或语言匹配内嵌轨（不区分大小写）', () {
      expect(matchEmbeddedSubtitle(_embedded, 'hls chinese'), 0);
      expect(matchEmbeddedSubtitle(_embedded, 'ZH'), 0);
      expect(matchEmbeddedSubtitle(_embedded, 'ja'), 1);
      expect(matchEmbeddedSubtitle(_embedded, '内嵌字幕 3'), 2);
      expect(matchEmbeddedSubtitle(_embedded, 'fr'), -1);
    });
  });

  group('pickSubtitle（按源记住的选择）', () {
    SubtitleChoice pick(
      SubtitlePreference? p, {
      List<SubtitleRef> external = _subs,
      List<EmbeddedSubtitle> embedded = _embedded,
      Set<int> failed = const {},
    }) => pickSubtitle(
      preference: p,
      external: external,
      embedded: embedded,
      failed: failed,
    );

    test('没有记录：第一条外挂字幕；没有外挂字幕则关闭（内嵌轨不自动选）', () {
      expect(pick(null), const SubtitleChoiceExternal(0));
      expect(pick(null, external: const []), const SubtitleChoiceOff());
    });

    test('记录为关闭', () {
      expect(pick(const SubtitleOff()), const SubtitleChoiceOff());
    });

    test('记录为标签：先外挂字幕，再内嵌轨', () {
      expect(
        pick(const SubtitleLabel('english')),
        const SubtitleChoiceExternal(1),
      );
      expect(
        pick(const SubtitleLabel('字幕 3')),
        const SubtitleChoiceExternal(2),
      );
      expect(
        pick(const SubtitleLabel('HLS Chinese')),
        const SubtitleChoiceEmbedded('HLS Chinese'),
      );
      expect(
        pick(const SubtitleLabel('zh')),
        const SubtitleChoiceEmbedded('zh'),
      );
    });

    test('标签找不到：回到默认规则', () {
      expect(
        pick(const SubtitleLabel('Français')),
        const SubtitleChoiceExternal(0),
      );
      expect(
        pick(const SubtitleLabel('Français'), external: const []),
        const SubtitleChoiceOff(),
      );
    });

    test('跳过加载失败的外挂字幕', () {
      expect(pick(null, failed: {0}), const SubtitleChoiceExternal(1));
      expect(
        pick(const SubtitleLabel('简体中文'), failed: {0}),
        const SubtitleChoiceExternal(1),
      );
      expect(pick(null, failed: {0, 1, 2}), const SubtitleChoiceOff());
    });

    test('选择 → 记住的偏好', () {
      expect(
        subtitlePreferenceFor(const SubtitleChoiceOff(), _subs),
        const SubtitleOff(),
      );
      expect(
        subtitlePreferenceFor(const SubtitleChoiceExternal(2), _subs),
        const SubtitleLabel('字幕 3'),
      );
      expect(
        subtitlePreferenceFor(const SubtitleChoiceEmbedded('ja'), _subs),
        const SubtitleLabel('ja'),
      );
    });
  });

  group('偏好存储', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('tsumugi_subs'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('按源保存与读取；文件损坏时视为没有记录', () async {
      final file = File('${dir.path}/sub/video_subtitles.json');
      final store = FileSubtitlePreferencesStore(() async => file);
      expect(await store.load('a'), isNull);
      await store.save('a', const SubtitleLabel('简体中文'));
      await store.save('b', const SubtitleOff());
      final reopened = FileSubtitlePreferencesStore(() async => file);
      expect(await reopened.load('a'), const SubtitleLabel('简体中文'));
      expect(await reopened.load('b'), const SubtitleOff());
      expect(await reopened.load('c'), isNull);

      file.writeAsStringSync('{not json');
      expect(await reopened.load('a'), isNull);
      await reopened.save('a', const SubtitleOff());
      expect(await reopened.load('a'), const SubtitleOff());
    });

    test('未知的记录形状被忽略', () {
      expect(SubtitlePreference.fromJson({'label': 3}), isNull);
      expect(SubtitlePreference.fromJson('x'), isNull);
      expect(SubtitlePreference.fromJson({'off': false}), isNull);
    });
  });

  group('VideoSubtitleController', () {
    late ValueNotifier<VideoPlaybackState> playback;
    late StreamController<List<String>> embedded;
    late VideoSubtitleController controller;

    setUp(() {
      playback = ValueNotifier(const VideoPlaybackState());
      embedded = StreamController<List<String>>.broadcast(sync: true);
      controller = VideoSubtitleController(
        playback: playback,
        embeddedText: embedded.stream,
      );
    });
    tearDown(() {
      controller.dispose();
      embedded.close();
      playback.dispose();
    });

    void at(int ms) => playback.value = VideoPlaybackState(
      position: Duration(milliseconds: ms),
    );

    test('外挂字幕随播放位置变化', () {
      controller.showDocument(_doc());
      expect(controller.value, '');
      at(1500);
      expect(controller.value, '第一条');
      at(2500);
      expect(controller.value, '');
      at(3000);
      expect(controller.value, '第二条');
      controller.hide();
      expect(controller.value, '');
    });

    test('内嵌轨显示播放器报告的文字；不显示时忽略', () {
      embedded.add(['ignored', '']);
      expect(controller.value, '');
      controller.showEmbedded();
      expect(controller.value, 'ignored');
      embedded.add(['  HLS subtitle 1\n', '']);
      expect(controller.value, 'HLS subtitle 1');
      // 换回外挂字幕：不再显示内嵌文字。
      at(1200);
      controller.showDocument(_doc());
      expect(controller.value, '第一条');
      embedded.add(['HLS subtitle 2', '']);
      expect(controller.value, '第一条');
    });
  });

  testWidgets('VideoSubtitleOverlay：显示文字、不拦截手势', (tester) async {
    final text = ValueNotifier('');
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => taps++,
              ),
            ),
            Positioned.fill(child: VideoSubtitleOverlay(text: text)),
          ],
        ),
      ),
    );
    expect(find.byKey(const ValueKey('video-subtitle-text')), findsNothing);
    text.value = '第一行\n第二行';
    await tester.pump();
    final shown = tester.widget<Text>(
      find.byKey(const ValueKey('video-subtitle-text')),
    );
    expect(shown.data, '第一行\n第二行');
    // 字幕层是 IgnorePointer：点击落到下面的手势上。
    await tester.tap(
      find.byKey(const ValueKey('video-subtitle-text')),
      warnIfMissed: false,
    );
    expect(taps, 1);
    text.value = '';
    await tester.pump();
    expect(find.byKey(const ValueKey('video-subtitle-text')), findsNothing);
  });
}
