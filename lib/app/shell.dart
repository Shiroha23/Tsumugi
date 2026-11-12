import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// 顶层导航外壳：窄屏用底部 NavigationBar，宽屏（桌面/平板）用侧边 NavigationRail。
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.shell});

  final StatefulNavigationShell shell;

  static const _destinations = [
    (
      icon: Icons.collections_bookmark_outlined,
      selected: Icons.collections_bookmark,
      label: '书架',
    ),
    (icon: Icons.search_outlined, selected: Icons.search, label: '搜索'),
    (icon: Icons.extension_outlined, selected: Icons.extension, label: '源'),
    (icon: Icons.settings_outlined, selected: Icons.settings, label: '设置'),
  ];

  static const wideBreakpoint = 640.0;

  void _onSelect(int index) =>
      shell.goBranch(index, initialLocation: index == shell.currentIndex);

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= wideBreakpoint;

    if (wide) {
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: shell.currentIndex,
              onDestinationSelected: _onSelect,
              labelType: NavigationRailLabelType.all,
              destinations: [
                for (final d in _destinations)
                  NavigationRailDestination(
                    icon: Icon(d.icon),
                    selectedIcon: Icon(d.selected),
                    label: Text(d.label),
                  ),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(child: shell),
          ],
        ),
      );
    }

    return Scaffold(
      body: shell,
      bottomNavigationBar: NavigationBar(
        selectedIndex: shell.currentIndex,
        onDestinationSelected: _onSelect,
        destinations: [
          for (final d in _destinations)
            NavigationDestination(
              icon: Icon(d.icon),
              selectedIcon: Icon(d.selected),
              label: d.label,
            ),
        ],
      ),
    );
  }
}
