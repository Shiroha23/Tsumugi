import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../shared/download/providers.dart';
import '../downloads/downloads_view.dart' show formatBytes;
import 'settings_routes.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        children: [
          const _DownloadsTile(),
          ListTile(
            leading: const Icon(Icons.sync),
            title: const Text('WebDAV 同步'),
            subtitle: const Text('在多台设备间同步书架、进度与源'),
            onTap: () => context.push(SettingsRoutes.sync),
          ),
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

/// 已下载内容的总占用与「清空」（architecture §4.5）。
class _DownloadsTile extends ConsumerWidget {
  const _DownloadsTile();

  Future<void> _confirmClear(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空下载'),
        content: const Text('确定删除全部已下载的漫画与小说吗？阅读进度会保留，此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(downloadManagerProvider).deleteAll();
    ref.invalidate(downloadTotalBytesProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final total = ref.watch(downloadTotalBytesProvider);
    // 只在 unit 增删或状态变化时重新统计占用（下载中的进度更新不触发全目录扫描）。
    ref.listen(
      allDownloadUnitsProvider.select(
        (v) => {
          for (final u in v.value ?? const <DownloadUnit>[])
            '${u.sourceId}\n${u.itemId}\n${u.unitId}': u.status,
        }.toString(),
      ),
      (_, _) => ref.invalidate(downloadTotalBytesProvider),
    );
    return ListTile(
      leading: const Icon(Icons.download_outlined),
      title: const Text('已下载内容'),
      subtitle: Text(switch (total) {
        AsyncData(:final value) => '占用 ${formatBytes(value)}',
        AsyncError() => '无法统计占用',
        _ => '正在统计…',
      }),
      trailing: TextButton(
        onPressed: total.value == null || total.value == 0
            ? null
            : () => _confirmClear(context, ref),
        child: const Text('清空'),
      ),
    );
  }
}
