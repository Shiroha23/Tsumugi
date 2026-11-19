import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/storage/app_database.dart';
import 'package:tsumugi/features/settings/sync/sync_settings_page.dart';
import 'package:tsumugi/shared/sync/providers.dart';
import 'package:tsumugi/sources/registry/providers.dart';

import '../../core/storage/test_database.dart';

String _manifest({String version = '1.0.0', List<String>? hosts}) {
  final json = jsonDecode(
    File('test/fixtures/sources/settings_comic.json').readAsStringSync(),
  ) as Map<String, Object?>;
  return jsonEncode({...json, 'version': version, 'allowedHosts': ?hosts});
}

PendingSource _pending(String manifest, {bool isUpdate = false}) =>
    PendingSource(
      id: 'com.example.settings',
      name: '设置示例',
      version: (jsonDecode(manifest) as Map)['version'] as String,
      manifest: manifest,
      enabled: false,
      sortOrder: 3,
      settings: const {'quality': 'low'},
      originKind: 'local',
      originUrl: null,
      modifiedAt: 1000,
      isUpdate: isUpdate,
    );

void main() {
  late AppDatabase db;
  late MemoryCredentialStore credentials;

  setUp(() {
    db = openTestDatabase();
    credentials = MemoryCredentialStore();
  });

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          credentialStoreProvider.overrideWithValue(credentials),
        ],
        child: const MaterialApp(home: SyncSettingsPage()),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await db.close();
    });
  }

  Future<void> configure() => SyncStore(db).saveConfig(
    serverUrl: 'https://dav.example.com/',
    username: 'alice',
    remoteDir: 'Tsumugi/',
  );

  testWidgets(
    'saving the form stores the password only in the credential store',
    (tester) async {
      await pump(tester);
      expect(find.text('立即同步'), findsNothing);

      await tester.enterText(
        find.byKey(const ValueKey('sync-url')),
        'http://dav.example.com/',
      );
      await tester.enterText(find.byKey(const ValueKey('sync-user')), 'alice');
      await tester.enterText(
        find.byKey(const ValueKey('sync-password')),
        'p@ss',
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.textContaining('只支持 https 地址'), findsOneWidget);
      expect(credentials.password, isNull);

      await tester.enterText(
        find.byKey(const ValueKey('sync-url')),
        'https://dav.example.com/dav',
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.text('已保存'), findsOneWidget);
      expect(credentials.password, 'p@ss');
      final row = await db.select(db.syncState).getSingle();
      expect(row.serverUrl, 'https://dav.example.com/dav/');
      expect(row.remoteDir, 'Tsumugi/');
      // 密码不进数据库。
      expect(jsonEncode(row.toJson()), isNot(contains('p@ss')));
      expect(find.text('立即同步'), findsOneWidget);
      expect(find.text('自动同步'), findsOneWidget);
    },
  );

  testWidgets('shows the last error and the concurrency warning', (
    tester,
  ) async {
    await configure();
    final store = SyncStore(db);
    await store.recordFailure('用户名或密码错误', attemptAt: 0);
    await (db.update(db.syncState)..where((t) => t.id.equals(1))).write(
      const SyncStateCompanion(conditionalUnsupported: Value(true)),
    );
    await pump(tester);
    expect(find.text('用户名或密码错误'), findsOneWidget);
    expect(find.text('服务器不支持并发保护'), findsOneWidget);
    expect(find.textContaining('不加密'), findsOneWidget);
  });

  Future<void> setPending(List<PendingSource> pending) =>
      (db.update(db.syncState)..where((t) => t.id.equals(1))).write(
        SyncStateCompanion(
          pendingSourcesJson: Value(
            jsonEncode([for (final p in pending) p.toJson()]),
          ),
        ),
      );

  testWidgets('pending source: preview, then install with synced settings', (
    tester,
  ) async {
    await configure();
    await setPending([_pending(_manifest())]);
    await pump(tester);
    expect(find.text('待安装的源'), findsOneWidget);
    expect(find.text('设置示例'), findsOneWidget);
    expect(await SourceRegistry(db).getAll(), isEmpty);

    await tester.tap(find.text('预览'));
    await tester.pumpAndSettle();
    expect(find.text('安装同步来的源'), findsOneWidget);
    expect(find.text('example.com'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '安装'));
    await tester.pumpAndSettle();

    final installed = (await SourceRegistry(db).get('com.example.settings'))!;
    expect(installed.enabled, isFalse);
    expect(installed.settings['quality'], 'low');
    expect(find.text('待安装的源'), findsNothing);
  });

  testWidgets('updates with new hosts need an extra confirmation', (
    tester,
  ) async {
    await configure();
    await SourceRegistry(db).importText(_manifest());
    await setPending([
      _pending(
        _manifest(
          version: '2.0.0',
          hosts: ['*.example.com', 'cdn.example.net'],
        ),
        isUpdate: true,
      ),
    ]);
    await pump(tester);
    await tester.tap(find.text('预览'));
    await tester.pumpAndSettle();
    expect(find.text('更新同步来的源'), findsOneWidget);
    expect(find.text('cdn.example.net（新增）'), findsOneWidget);
    final install = find.widgetWithText(FilledButton, '更新');
    expect(tester.widget<FilledButton>(install).onPressed, isNull);

    await tester.tap(find.text('允许访问新增的 1 个主机'));
    await tester.pump();
    expect(tester.widget<FilledButton>(install).onPressed, isNotNull);
    await tester.tap(install);
    await tester.pumpAndSettle();
    expect(
      (await SourceRegistry(db).get('com.example.settings'))!.version,
      '2.0.0',
    );
  });

  testWidgets('dismissed sources move to the bottom and can be restored', (
    tester,
  ) async {
    await configure();
    await setPending([_pending(_manifest())]);
    await pump(tester);
    await tester.tap(find.text('忽略'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已忽略'), findsOneWidget);
    await tester.tap(find.text('恢复'));
    await tester.pumpAndSettle();
    expect(find.text('预览'), findsOneWidget);
  });
}
