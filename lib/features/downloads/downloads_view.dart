import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../shared/download/providers.dart';
import '../../shared/image/source_image.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/source_error_view.dart';
import '../../sources/model/common.dart';
import '../../sources/registry/providers.dart';
import '../../sources/runtime/source_error_text.dart';
import '../../sources/source.dart';
import '../comic/reader/reader_route.dart';
import '../novel/novel_routes.dart';
import '../video/video_routes.dart';
import 'download_routes.dart';

/// 书架的「下载」标签：下载的条目，点击进入章节状态页（architecture §4.5）。
class DownloadsTab extends ConsumerWidget {
  const DownloadsTab({super.key});

  static bool get _iosHint => defaultTargetPlatform == TargetPlatform.iOS;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(downloadItemsProvider);
    final units = ref.watch(allDownloadUnitsProvider).value ?? const [];
    final sources = {
      for (final s in ref.watch(installedSourcesProvider()).value ?? const [])
        s.id: s,
    };
    return switch (items) {
      AsyncData(:final value) when value.isEmpty => const EmptyState(
        icon: Icons.download_outlined,
        message: '还没有下载的内容',
      ),
      AsyncData(:final value) => ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: value.length + (_iosHint ? 1 : 0),
        itemBuilder: (context, index) {
          if (_iosHint && index == 0) {
            // iOS 只允许在后台继续约 30 秒（architecture §4.5.1「后台下载」）。
            return ListTile(
              dense: true,
              leading: const Icon(Icons.info_outline),
              title: Text(
                'iOS 上切到后台约 30 秒后下载会暂停，回到应用时自动继续。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            );
          }
          final i = index - (_iosHint ? 1 : 0);
          final d = value[i];
          final mine = [
            for (final u in units)
              if (u.sourceId == d.sourceId && u.itemId == d.itemId) u,
          ];
          final done = mine.where((u) => u.status == DownloadStatus.done);
          final source = sources[d.sourceId];
          return ListTile(
            leading: SizedBox(
              width: 42,
              child: CoverImage(
                sourceId: d.sourceId,
                url: d.item.cover,
                headers: d.item.coverHeaders,
              ),
            ),
            title: Text(
              d.item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '${source?.name ?? '源已删除'} · 已下载 ${done.length} / ${mine.length} '
              '${d.item.mediaType == MediaType.video ? '集' : '章'}'
              '${_summary(mine)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () =>
                context.push(DownloadRoutes.item(d.sourceId, d.itemId)),
          );
        },
      ),
      AsyncError(:final error) => EmptyState(
        icon: Icons.error_outline,
        message: '下载列表加载失败：$error',
      ),
      _ => const Center(child: CircularProgressIndicator()),
    };
  }

  static String _summary(List<DownloadUnit> units) {
    if (units.any((u) => u.status == DownloadStatus.running)) return ' · 下载中';
    if (units.any((u) => u.pausesSource)) return ' · 已暂停（需要处理）';
    if (units.any((u) => u.status == DownloadStatus.failed)) return ' · 有失败';
    if (units.any((u) => u.status == DownloadStatus.queued)) return ' · 排队中';
    if (units.any((u) => u.status == DownloadStatus.paused)) return ' · 已暂停';
    return '';
  }
}

/// 一个条目的下载：章节状态、进度，暂停 / 继续 / 重试 / 删除；已下载的章节点击打开阅读器
/// （离线时阅读器按下载时的详情快照显示目录）。
class DownloadItemPage extends ConsumerWidget {
  const DownloadItemPage({
    super.key,
    required this.sourceId,
    required this.itemId,
  });

  final String sourceId;
  final String itemId;

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    String title, {
    DownloadUnit? unit,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除下载'),
        content: Text(
          unit == null
              ? '确定删除「$title」的全部下载吗？阅读进度会保留。'
              : '确定删除「${unit.title}」的下载吗？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final manager = ref.read(downloadManagerProvider);
    if (unit == null) {
      await manager.deleteItem(sourceId, itemId);
      if (context.mounted) context.pop();
    } else {
      await manager.deleteUnit(unit);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final item = ref.watch(downloadItemProvider(sourceId, itemId)).value;
    final units =
        ref.watch(downloadUnitsProvider(sourceId, itemId)).value ?? const [];
    final manager = ref.read(downloadManagerProvider);
    final title = item?.item.title ?? '';
    // 按源判断：同源其他条目的验证错误同样让本条目停在排队中。
    final pausing = (ref.watch(allDownloadUnitsProvider).value ?? units)
        .where((u) => u.sourceId == sourceId && u.pausesSource)
        .firstOrNull;
    final active = units.any(
      (u) =>
          u.status == DownloadStatus.queued ||
          u.status == DownloadStatus.running,
    );
    final resumable = units.any(
      (u) =>
          u.status == DownloadStatus.paused ||
          u.status == DownloadStatus.failed,
    );
    final groups = <String>{for (final u in units) u.groupName};

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          if (active)
            IconButton(
              tooltip: '全部暂停',
              icon: const Icon(Icons.pause),
              onPressed: () => manager.pauseItem(sourceId, itemId),
            ),
          if (resumable)
            IconButton(
              tooltip: '全部继续',
              icon: const Icon(Icons.play_arrow),
              onPressed: () => manager.resumeItem(sourceId, itemId),
            ),
          IconButton(
            tooltip: '删除全部下载',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _confirmDelete(context, ref, title),
          ),
        ],
      ),
      body: ListView(
        children: [
          if (pausing != null) _SourcePausedBanner(unit: pausing),
          for (final u in units)
            _UnitTile(
              unit: u,
              showGroup: groups.length > 1,
              onOpen: item == null || u.status != DownloadStatus.done
                  ? null
                  : () => context.push(switch (item.item.mediaType) {
                      MediaType.novel => NovelRoutes.reader(
                        sourceId,
                        itemId,
                        u.unitId,
                      ),
                      MediaType.video => VideoRoutes.player(
                        sourceId,
                        itemId,
                        u.unitId,
                      ),
                      _ => comicReaderLocation(sourceId, itemId, u.unitId),
                    }),
              onDelete: () => _confirmDelete(context, ref, title, unit: u),
            ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

/// 整个源因验证 / 登录或源不可用而暂停时的提示：验证类错误提供「打开验证页」，完成后自动继续。
class _SourcePausedBanner extends ConsumerWidget {
  const _SourcePausedBanner({required this.unit});

  final DownloadUnit unit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manager = ref.read(downloadManagerProvider);
    void resume() => manager.resumeSource(unit.sourceId);
    final code = SourceErrorCode.fromWire(unit.errorCode ?? '');
    if (code == null) {
      return Card(
        margin: const EdgeInsets.all(12),
        child: ListTile(
          leading: const Icon(Icons.pause_circle_outline),
          title: const Text('源不可用，该源的下载已暂停'),
          subtitle: const Text('源已被删除、禁用或清单无法加载。恢复后点「继续」。'),
          trailing: TextButton(onPressed: resume, child: const Text('继续')),
        ),
      );
    }
    return Card(
      margin: const EdgeInsets.all(12),
      child: SourceErrorView(
        error: SourceException(code, '该源的下载已暂停，完成验证 / 登录后自动继续'),
        sourceId: unit.sourceId,
        onRetry: resume,
        compact: true,
      ),
    );
  }
}

class _UnitTile extends ConsumerWidget {
  const _UnitTile({
    required this.unit,
    required this.showGroup,
    required this.onOpen,
    required this.onDelete,
  });

  final DownloadUnit unit;
  final bool showGroup;
  final VoidCallback? onOpen;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manager = ref.read(downloadManagerProvider);
    final u = unit;
    final status = switch (u.status) {
      DownloadStatus.done => '已下载',
      DownloadStatus.running => [
        '下载中',
        if (u.totalFiles > 1) ' ${u.completedFiles} / ${u.totalFiles}',
        if (u.bytes > 0) ' · ${formatBytes(u.bytes)}',
      ].join(),
      DownloadStatus.queued => '排队中',
      DownloadStatus.paused => u.pausesSource ? '已暂停（需要处理）' : '已暂停',
      DownloadStatus.failed => '失败：${_errorText(u.errorCode)}',
    };
    final size = u.status == DownloadStatus.done
        ? ' · ${formatBytes(u.bytes)}'
        : '';
    return ListTile(
      title: Text(u.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${showGroup ? '${u.groupName} · ' : ''}$status$size'),
          if (u.status == DownloadStatus.running && u.totalFiles > 1)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: LinearProgressIndicator(
                value: u.completedFiles / u.totalFiles,
              ),
            ),
        ],
      ),
      onTap: onOpen,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (u.status == DownloadStatus.queued ||
              u.status == DownloadStatus.running)
            IconButton(
              tooltip: '暂停',
              icon: const Icon(Icons.pause),
              onPressed: () => manager.pause(u),
            ),
          if (u.status == DownloadStatus.paused)
            IconButton(
              tooltip: '继续',
              icon: const Icon(Icons.play_arrow),
              onPressed: () => manager.resume(u),
            ),
          if (u.status == DownloadStatus.failed)
            IconButton(
              tooltip: '重试',
              icon: const Icon(Icons.refresh),
              onPressed: () => manager.resume(u),
            ),
          IconButton(
            tooltip: '删除',
            icon: const Icon(Icons.delete_outline),
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }

  static String _errorText(String? code) => switch (code) {
    downloadFilesMissing => '本地文件缺失或损坏',
    downloadIoError || downloadStorageError => '写入文件失败（存储空间不足？）',
    downloadSourceUnavailable => '源不可用',
    null => '未知错误',
    final c => switch (SourceErrorCode.fromWire(c)) {
      final known? => describeSourceError(SourceException(known)).title,
      null => c,
    },
  };
}

/// 字节数的简短显示：`512 B` / `1.2 MB`。
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var v = bytes / 1024;
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v >= 100 ? 0 : 1)} ${units[i]}';
}
