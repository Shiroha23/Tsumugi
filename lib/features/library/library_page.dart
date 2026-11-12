import 'package:flutter/material.dart';

import '../../shared/widgets/empty_state.dart';

class LibraryPage extends StatelessWidget {
  const LibraryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('书架')),
      body: const EmptyState(
        icon: Icons.collections_bookmark_outlined,
        message: '书架是空的',
      ),
    );
  }
}
