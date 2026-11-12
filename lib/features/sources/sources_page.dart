import 'package:flutter/material.dart';

import '../../shared/widgets/empty_state.dart';

class SourcesPage extends StatelessWidget {
  const SourcesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('源')),
      body: const EmptyState(
        icon: Icons.extension_outlined,
        message: '还没有安装任何源',
      ),
    );
  }
}
