import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/app/app.dart';

Future<void> _pump(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(const ProviderScope(child: TsumugiApp()));
  await tester.pumpAndSettle();
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
