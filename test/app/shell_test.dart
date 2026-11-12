import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/app/app.dart';
import 'package:tsumugi/core/storage/app_database.dart';

import '../core/storage/test_database.dart';

Future<void> _pump(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final db = openTestDatabase();
  addTearDown(db.close);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
      child: const TsumugiApp(),
    ),
  );
  await tester.pumpAndSettle();
  // 先卸载，让 drift 的 stream 在数据库关闭前结束。
  addTearDown(() => tester.pumpWidget(const SizedBox()));
}

void main() {
  testWidgets('窄屏使用底部导航，并能切换页面', (tester) async {
    await _pump(tester, const Size(400, 800));

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('书架是空的'), findsOneWidget);

    await tester.tap(find.text('源'));
    await tester.pumpAndSettle();
    expect(find.text('还没有安装任何源'), findsOneWidget);
  });

  testWidgets('宽屏使用侧边导航', (tester) async {
    await _pump(tester, const Size(1200, 800));

    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
  });
}
