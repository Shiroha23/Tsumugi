import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/features/novel/novel_routes.dart';
import 'package:tsumugi/shared/export/providers.dart';
import 'package:tsumugi/sources/model/common.dart';
import 'package:tsumugi/sources/model/content.dart';
import 'package:tsumugi/sources/runtime/source_runtime.dart';
import 'package:tsumugi/sources/source.dart';

import '../../sources/runtime/runtime_support.dart';
import '../app_harness.dart';

/// 详情页“导出”：选择格式与范围 → 进度 → 失败暂停（验证 / 跳过）→ 保存。
const _sourceId = 'com.example.novel';
const _itemId = '/novel/book/1';

const _detail = Detail(
  id: _itemId,
  title: '青石巷的钟表匠',
  author: '虚构作者丁',
  units: [
    Unit(id: 'c1', title: '第一章 倒走的怀表'),
    Unit(id: 'c2', title: '第二章 雨季'),
    Unit(id: 'c3', title: '第三章 风铃'),
  ],
);

class _FakeSaver implements ExportSaver {
  final saved = <ExportFile>[];

  @override
  Future<String?> save(ExportFile file) async {
    saved.add(file);
    return 'C:\\Exports\\${file.fileName}';
  }
}

void main() {
  late _FakeSaver saver;

  AppHarness harness(Future<MediaContent> Function(String id) onContent) {
    saver = _FakeSaver();
    return AppHarness(
      FakeFactory(
        (m) =>
            FakeSource(m, onDetail: (_) async => _detail, onContent: onContent),
      ),
      overrides: [
        novelExporterProvider.overrideWith(
          (ref) => NovelExporter(
            sourceFor: ref.watch(sourceRuntimeProvider).get,
            buildInIsolate: false,
          ),
        ),
        exportSaverProvider.overrideWithValue(saver),
      ],
    );
  }

  Future<void> openExport(WidgetTester tester, AppHarness app) async {
    await app.install(tester, [
      fakeManifestJson(_sourceId, name: '小说源', type: MediaType.novel),
    ]);
    await app.pump(tester);
    app.router.push(NovelRoutes.detail(_sourceId, _itemId));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, '导出'));
    await tester.pumpAndSettle();
    expect(find.text('导出小说'), findsOneWidget);
  }

  testWidgets('导出起止章节为 TXT 并保存', (tester) async {
    final app = harness((id) async => NovelContent(text: '$id 的正文'));
    await openExport(tester, app);

    await tester.tap(find.text('TXT'));
    await tester.tap(find.text('起止章节'));
    await tester.pumpAndSettle();
    // 从第二章到第三章。
    await tester.tap(find.byKey(const ValueKey('export-range-从')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2. 第二章 雨季').last);
    await tester.pumpAndSettle();
    expect(find.text('将导出 2 章。章节按顺序逐一请求，遵守该源的限速，章节较多时需要一些时间。'), findsOneWidget);

    await tester.tap(find.text('开始导出'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已导出 2 / 2 章'), findsOneWidget);
    expect(find.text('青石巷的钟表匠.txt'), findsOneWidget);

    await tester.tap(find.text('保存文件'));
    await tester.pumpAndSettle();
    expect(find.text('已保存到：C:\\Exports\\青石巷的钟表匠.txt'), findsOneWidget);
    final text = utf8.decode(saver.saved.single.bytes);
    expect(text, contains('来源：小说源'));
    expect(text, isNot(contains('c1 的正文')));
    expect(text, contains('第二章 雨季\n\n　　c2 的正文'));
    expect(text, contains('第三章 风铃\n\n　　c3 的正文'));

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('导出小说'), findsNothing);
    await app.dispose(tester);
  });

  testWidgets('需要验证时暂停：打开验证页完成后继续；普通失败可跳过并列出', (tester) async {
    var verified = false;
    final app = harness((id) async {
      if (id == 'c1' && !verified) {
        throw const SourceException(SourceErrorCode.challenge);
      }
      if (id == 'c2') throw const SourceException(SourceErrorCode.network);
      return NovelContent(text: '$id 的正文');
    });
    await openExport(tester, app);
    await tester.tap(find.text('开始导出'));
    await tester.pumpAndSettle();

    expect(find.text('「第一章 倒走的怀表」导出失败（1 / 3）'), findsOneWidget);
    expect(find.text('需要验证'), findsOneWidget);
    // 需要验证时不提供“跳过所有失败章节”。
    expect(find.text('跳过所有失败章节'), findsNothing);
    verified = true;
    await tester.tap(find.text('打开验证页'));
    await tester.pumpAndSettle();
    expect(app.verification.calls, [_sourceId]);

    expect(find.text('「第二章 雨季」导出失败（2 / 3）'), findsOneWidget);
    await tester.tap(find.text('跳过本章'));
    await tester.pumpAndSettle();

    expect(find.textContaining('已导出 2 / 3 章'), findsOneWidget);
    expect(find.text('已跳过 1 章：'), findsOneWidget);
    expect(find.text('· 第二章 雨季：网络错误或超时'), findsOneWidget);
    await tester.tap(find.text('保存文件'));
    await tester.pumpAndSettle();
    expect(saver.saved.single.fileName, '青石巷的钟表匠.epub');
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await app.dispose(tester);
  });

  testWidgets('导出中取消', (tester) async {
    final app = harness(
      (id) => Future.delayed(
        const Duration(seconds: 1),
        () => NovelContent(text: '$id 的正文'),
      ),
    );
    await openExport(tester, app);
    await tester.tap(find.text('开始导出'));
    await tester.pump();
    await tester.pump();
    expect(find.text('正在导出 1 / 3：第一章 倒走的怀表'), findsOneWidget);
    await tester.tap(find.text('取消导出'));
    await tester.pumpAndSettle();
    expect(find.text('导出小说'), findsNothing);
    // 让进行中的（已被丢弃的）请求结束，之后不再请求后续章节。
    await tester.pump(const Duration(seconds: 2));
    await app.dispose(tester);
  });
}
