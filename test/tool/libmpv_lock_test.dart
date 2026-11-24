// windows/libmpv.lock（Windows 自建 libmpv 的固定地址与 sha256，architecture §6.4.6 第 2 项）与
// 源码清单、许可证声明一致。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/features/settings/about/native_licenses.dart';
import 'package:flutter/foundation.dart';

Map<String, String> readLock() => {
  for (final line in File('windows/libmpv.lock').readAsLinesSync())
    if (line.isNotEmpty && !line.startsWith('#'))
      line.split('\t')[0]: line.split('\t')[1],
};

void main() {
  final lock = readLock();
  final tag = lock['tag']!;
  const releases =
      'https://github.com/Shiroha23/Tsumugi-libmpv/releases/download/';

  test('清单字段齐全，地址指向 Tsumugi-libmpv 中同一标签的 Release', () {
    expect(
      lock.keys,
      containsAll([
        'tag',
        'mpv',
        'ffmpeg',
        'zip_url',
        'zip_sha256',
        'sources_url',
        'sources_sha256',
      ]),
    );
    expect(tag, matches(RegExp(r'^libmpv-win-[0-9.]+-ff[0-9.]+-r[0-9]+$')));
    expect(
      tag,
      'libmpv-win-${lock['mpv']}-ff${lock['ffmpeg']}-${tag.split('-').last}',
    );
    expect(lock['zip_url'], '$releases$tag/$tag.zip');
    expect(lock['sources_url'], '$releases$tag/$tag-sources.tar');
    for (final key in ['zip_sha256', 'sources_sha256']) {
      expect(lock[key], matches(RegExp(r'^[0-9a-f]{64}$')), reason: key);
      // 占位值（全零）不能合并：发版时源码包校验会失败（Codex 审查第 1 条）。
      expect(lock[key], isNot('0' * 64), reason: key);
    }
  });

  test('源码清单的 Windows libmpv 源码包与清单一致', () {
    final rows = File('tool/release/native_sources.tsv')
        .readAsLinesSync()
        .where((l) => l.isNotEmpty && !l.startsWith('#'))
        .map((l) => l.split('\t'))
        .where((r) => r[0].split(',').contains('windows'))
        .toList();
    final libmpv = rows.where((r) => r[4].startsWith(releases)).toList();
    expect(libmpv, hasLength(1));
    expect(libmpv.single[2], tag);
    expect(libmpv.single[4], lock['sources_url']);
    expect(libmpv.single[5], lock['sources_sha256']);
    // 旧的 2023 版 Windows mpv / FFmpeg 不再随包，也不再收源码。
    expect(rows.where((r) => r[1] == 'mpv' || r[1] == 'FFmpeg'), isEmpty);
  });

  test('许可证声明中的 Windows mpv / FFmpeg 版本与清单一致', () {
    String windows(String name) => nativeComponents
        .singleWhere((c) => c.name == name)
        .versions[TargetPlatform.windows]!;
    expect(windows('mpv (libmpv)'), lock['mpv']);
    expect(windows('FFmpeg'), lock['ffmpeg']);
    final notices = File('THIRD_PARTY_NOTICES.md').readAsStringSync();
    expect(notices, contains(tag));
  });
}
