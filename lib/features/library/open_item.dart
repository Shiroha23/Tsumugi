import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/history/providers.dart';
import '../../shared/library/providers.dart';

/// 打开一个书架 / 历史条目。[progress] 从历史打开时为该条目的最新进度，
/// 可用来直接跳到阅读器继续阅读；从书架打开时为 null。
typedef OpenLibraryItem = void Function(
  BuildContext context,
  LibraryItem item, {
  ItemProgress? progress,
});

/// 书架页点击条目时的跳转。详情页路由由“搜索与详情”接入，集成时覆盖本 provider
/// （例如 `context.push(Routes.detail(...))`）；为 null 时书架页提示“暂不可用”。
final openItemProvider = Provider<OpenLibraryItem?>((ref) => null);
