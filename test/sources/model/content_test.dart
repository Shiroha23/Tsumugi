import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/sources/model/common.dart';
import 'package:tsumugi/sources/model/content.dart';

void main() {
  test('按 MediaType 分派内容类型', () {
    final comic = MediaContent.fromJson(MediaType.comic, {
      'images': [
        {
          'url': 'https://img.example.com/1.jpg',
          'headers': {'Referer': 'https://example.com/'},
        },
      ],
    });
    expect(comic, isA<ComicContent>());
    expect(
      (comic as ComicContent).images.single.headers?['Referer'],
      'https://example.com/',
    );

    final video = MediaContent.fromJson(MediaType.video, {
      'streams': [
        {
          'url': 'https://example.com/a.m3u8',
          'type': 'hls',
          'quality': '1080p',
        },
        {'url': 'https://example.com/b', 'type': 'something-new'},
      ],
    }) as VideoContent;
    expect(video.streams.first.type, StreamType.hls);
    expect(video.streams.last.type, StreamType.auto, reason: '未知类型回退为 auto');

    final music = MediaContent.fromJson(MediaType.music, {
      'streams': [
        {'url': 'https://example.com/a.mp3'},
      ],
      'lyrics': {'format': 'lrc', 'content': '[00:00.00]hi'},
    }) as MusicContent;
    expect(music.lyrics?.format, LyricsFormat.lrc);

    final novel = MediaContent.fromJson(MediaType.novel, {
      'text': '第一段\n第二段',
    }) as NovelContent;
    expect(novel.html, isFalse);
  });

  test('Detail 未知状态回退为 unknown，分页结果解析', () {
    final d = Detail.fromJson({
      'id': '/b/1',
      'title': 't',
      'status': 'hiatus',
      'units': [
        {'id': '/c/1', 'title': '第 1 话'},
      ],
    });
    expect(d.status, SeriesStatus.unknown);
    expect(d.units.single.title, '第 1 话');

    final page = PageResult.fromJson({
      'items': [
        {'id': '/b/1', 'title': 't'},
      ],
      'hasMore': true,
    }, SearchItem.fromJson);
    expect(page.items.single.tags, isEmpty);
    expect(page.hasMore, isTrue);
  });
}
