import 'package:flutter/material.dart';

import '../../shared/widgets/empty_state.dart';

class SearchPage extends StatelessWidget {
  const SearchPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('搜索')),
      body: const EmptyState(
        icon: Icons.search_outlined,
        message: '先在「源」页面导入源，然后在这里搜索',
      ),
    );
  }
}
