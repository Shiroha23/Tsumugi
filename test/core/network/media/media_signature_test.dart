import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/network/media/media_signature.dart';

List<int> _pad(List<int> head, [int total = 64]) => [
  ...head,
  for (var i = head.length; i < total; i++) 0,
];

void main() {
  test('识别容器，扩展名与 FFmpeg HLS 的格式检查一致', () {
    final ts = File('test/fixtures/mock_site/video/clip.ts')
        .readAsBytesSync()
        .sublist(0, 1024);
    final cases = <(String, List<int>, MediaContainer)>[
      ('MPEG-TS', ts, MediaContainer.mpegTs),
      (
        'MP4 ftyp',
        _pad([0, 0, 0, 0x18, ...ascii.encode('ftypisom')]),
        MediaContainer.isoBmff,
      ),
      (
        'fMP4 moof',
        _pad([0, 0, 0, 0x10, ...ascii.encode('moof')]),
        MediaContainer.isoBmff,
      ),
      ('Matroska', _pad([0x1A, 0x45, 0xDF, 0xA3]), MediaContainer.matroska),
      ('FLV', _pad([...ascii.encode('FLV'), 1, 5]), MediaContainer.flv),
      ('Ogg', _pad([...ascii.encode('OggS'), 0, 2]), MediaContainer.ogg),
      ('ADTS', _pad([0xFF, 0xF1, 0x50, 0x80]), MediaContainer.adts),
      ('MPEG 音频', _pad([0xFF, 0xFB, 0x90, 0x64]), MediaContainer.mpegAudio),
      (
        'ID3 + ADTS',
        _pad([...ascii.encode('ID3'), 4, 0, 0, 0, 0, 0, 2, 0, 0, 0xFF, 0xF1]),
        MediaContainer.adts,
      ),
      (
        'ID3 + MP3',
        _pad([...ascii.encode('ID3'), 3, 0, 0, 0, 0, 0, 1, 0, 0xFF, 0xFB]),
        MediaContainer.mpegAudio,
      ),
      (
        'ID3（带尾部）+ E-AC-3',
        _pad([
          ...ascii.encode('ID3'), 4, 0, 0x10, 0, 0, 0, 0, //
          for (var i = 0; i < 10; i++) 0,
          0x0B, 0x77, 0, 0, 0, 16 << 3,
        ]),
        MediaContainer.eac3,
      ),
      (
        'ID3 之后超出已读范围：待补读（扩展名按 AAC）',
        _pad([...ascii.encode('ID3'), 4, 0, 0, 0, 0, 0x7F, 0x7F]),
        MediaContainer.id3,
      ),
      ('AC-3', _pad([0x0B, 0x77, 0, 0, 0, 8 << 3]), MediaContainer.ac3),
      ('E-AC-3', _pad([0x0B, 0x77, 0, 0, 0, 16 << 3]), MediaContainer.eac3),
      ('FLAC', _pad([...ascii.encode('fLaC'), 0]), MediaContainer.flac),
      (
        'AVI',
        _pad([...ascii.encode('RIFF'), 0, 0, 0, 0, ...ascii.encode('AVI ')]),
        MediaContainer.avi,
      ),
      (
        'WAV',
        _pad([...ascii.encode('RIFF'), 0, 0, 0, 0, ...ascii.encode('WAVE')]),
        MediaContainer.wav,
      ),
    ];
    for (final (name, bytes, expected) in cases) {
      expect(sniffMediaContainer(bytes), expected, reason: name);
      expect(looksLikeMediaContainer(bytes), isTrue, reason: name);
    }
    // FFmpeg 7.1.1+ 的 allowed_segment_extensions（n8.0.1）；flv 不在其中（HLS 中不常见，新版上一律被拒）。
    const allowed = {
      '3gp', 'aac', 'avi', 'ac3', 'eac3', 'flac', 'mkv', 'm3u8', 'm4a', //
      'm4s', 'm4v', 'mpg', 'mov', 'mp2', 'mp3', 'mp4', 'mpeg', 'mpegts',
      'ogg', 'ogv', 'oga', 'ts', 'vob', 'vtt', 'wav', 'webvtt', 'cmfv',
      'cmfa', 'ec3', 'fmp4', 'html',
    };
    for (final c in MediaContainer.values) {
      if (c == MediaContainer.flv) continue;
      expect(allowed, contains(c.extension), reason: c.name);
    }
    // 扩展名都不是播放列表 / 清单格式。
    for (final c in MediaContainer.values) {
      expect(const {
        'm3u8',
        'm3u',
        'pls',
        'mpd',
        'ffconcat',
        'edl',
        'html',
      }, isNot(contains(c.extension)));
    }
  });

  test('文本、BOM 与没有控制字节的内容不是媒体', () {
    for (final bytes in [
      utf8.encode('#EXTM3U\n#EXTINF:1,\nx.ts\n'),
      utf8.encode('<html><body>error</body></html>'),
      [0xFF, 0xFE, 0x23, 0, 0x45, 0], // UTF-16LE BOM（形如 MPEG 帧同步字）
      [0xFF, 0xF1, 0x50, 0x80, 0x41, 0x42], // 同步字但没有控制字节
      [0x47, 0, 0], // 太短
      _pad([...ascii.encode('RIFF'), 0, 0, 0, 0, ...ascii.encode('XXXX')]),
    ]) {
      expect(sniffMediaContainer(bytes), isNull, reason: '$bytes');
      expect(looksLikeMediaContainer(bytes), isFalse, reason: '$bytes');
    }
  });
}
