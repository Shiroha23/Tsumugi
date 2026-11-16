import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/features/settings/about/about_page.dart';
import 'package:tsumugi/features/settings/about/native_licenses.dart';

/// 直接从仓库的 `assets/` 读取，验证引用的许可证文件确实存在。
class _DiskBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async {
    final bytes = await File(key).readAsBytes();
    return ByteData.sublistView(bytes);
  }
}

void main() {
  group('native licenses', () {
    test('每个引用的许可证文件都存在，且没有未引用的文件', () {
      final referenced = {for (final c in nativeComponents) ...c.licenseFiles};
      final onDisk = Directory('assets/licenses')
          .listSync()
          .whereType<File>()
          .map((f) => f.uri.pathSegments.last)
          .toSet();
      expect(referenced.difference(onDisk), isEmpty, reason: '缺少的文件');
      expect(onDisk.difference(referenced), isEmpty, reason: '未引用的文件');
    });

    test('名称唯一，每个组件至少在一个平台随包', () {
      final names = nativeComponents.map((c) => c.name).toList();
      expect(names.toSet(), hasLength(names.length));
      for (final c in nativeComponents) {
        expect(c.versions, isNotEmpty, reason: c.name);
        expect(c.licenseFiles.isNotEmpty || c.note != null, isTrue);
      }
    });

    test('只对收进源码包的组件声称源码随 Release 发布', () async {
      for (final c in nativeComponents) {
        expect(c.versions.keys, containsAll(c.bundledSources), reason: c.name);
      }
      final entries = await nativeLicenseEntries(
        _DiskBundle(),
        TargetPlatform.windows,
      ).toList();
      String header(String name) => entries
          .firstWhere((e) => e.packages.contains(name))
          .paragraphs
          .first
          .text;
      const claim = '源码收在 Release';
      expect(header('mpv (libmpv)'), contains(claim));
      expect(header('GNU libiconv'), contains(claim));
      for (final name in [
        'ANGLE',
        'Microsoft Edge WebView2 SDK (WebView2Loader.dll)',
        'uchardet',
        'libass',
      ]) {
        expect(header(name), isNot(contains(claim)), reason: name);
      }
    });

    test('源码清单中 uchardet 只对应版本已知的 iOS', () {
      final rows = File('tool/release/native_sources.tsv')
          .readAsLinesSync()
          .where((l) => l.isNotEmpty && !l.startsWith('#'))
          .map((l) => l.split('\t'));
      final uchardet = rows.singleWhere((r) => r[1] == 'uchardet');
      expect(uchardet[0], 'ios');
    });

    test('THIRD_PARTY_NOTICES.md 列出了每个原生组件', () {
      final notices = File('THIRD_PARTY_NOTICES.md').readAsStringSync();
      for (final c in nativeComponents) {
        expect(notices, contains(c.name), reason: c.name);
      }
    });

    test('按平台生成许可证条目', () async {
      final bundle = _DiskBundle();
      for (final platform in [
        TargetPlatform.windows,
        TargetPlatform.android,
        TargetPlatform.iOS,
      ]) {
        final entries = await nativeLicenseEntries(bundle, platform).toList();
        final names = entries.expand((e) => e.packages).toSet();
        expect(names, containsAll(['Tsumugi', 'mpv (libmpv)', 'FFmpeg']));
        final ffmpeg = entries.firstWhere((e) => e.packages.contains('FFmpeg'));
        final text = ffmpeg.paragraphs.map((p) => p.text).join('\n');
        expect(text, contains('LGPL-3.0-or-later'));
        expect(text, contains('GNU LESSER GENERAL PUBLIC LICENSE'));
      }
      final android = await nativeLicenseEntries(
        bundle,
        TargetPlatform.android,
      ).expand((e) => e.packages).toList();
      expect(android, contains('media-kit-android-helper'));
      expect(android, isNot(contains('ANGLE')));
      final windows = await nativeLicenseEntries(
        bundle,
        TargetPlatform.windows,
      ).expand((e) => e.packages).toList();
      expect(windows, containsAll(['ANGLE', 'GNU libiconv']));
      expect(windows, isNot(contains('media-kit-android-helper')));
    });
  });

  group('AboutPage', () {
    Future<void> pump(WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appVersionProvider.overrideWith((ref) async => '1.2.3+4'),
          ],
          child: const MaterialApp(home: AboutPage()),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('显示版本、GPL-3.0 声明与源码地址', (tester) async {
      await pump(tester);
      expect(find.text('版本 1.2.3+4'), findsOneWidget);
      expect(find.textContaining('GPL-3.0-or-later'), findsOneWidget);
      expect(find.text(sourceRepositoryUrl), findsOneWidget);
      expect(find.text(releasesUrl), findsOneWidget);
    });

    testWidgets('复制源码地址', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await pump(tester);
      await tester.tap(find.byTooltip('复制地址').first);
      await tester.pump();
      expect(copied, sourceRepositoryUrl);
      expect(find.text('已复制'), findsOneWidget);
    });

    testWidgets('打开第三方许可证页', (tester) async {
      LicenseRegistry.reset();
      addTearDown(LicenseRegistry.reset);
      LicenseRegistry.addLicense(
        () => Stream.value(
          const LicenseEntryWithLineBreaks(['FFmpeg'], 'license text'),
        ),
      );
      await pump(tester);
      await tester.tap(find.text('第三方许可证'));
      await tester.pumpAndSettle();
      expect(find.text('FFmpeg'), findsOneWidget);
    });
  });
}
