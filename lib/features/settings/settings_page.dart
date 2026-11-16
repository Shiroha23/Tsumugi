import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'settings_routes.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('关于 Tsumugi'),
            subtitle: const Text('版本、许可证与源码'),
            onTap: () => context.push(SettingsRoutes.about),
          ),
        ],
      ),
    );
  }
}
