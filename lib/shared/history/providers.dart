import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../core/storage/app_database.dart';
import 'history_repository.dart';

export 'history_repository.dart';

part 'providers.g.dart';

@Riverpod(keepAlive: true)
HistoryRepository historyRepository(Ref ref) =>
    HistoryRepository(ref.watch(appDatabaseProvider));

/// 最近阅读，按时间倒序。
@riverpod
Stream<List<ItemProgress>> recentHistory(Ref ref, {int? limit}) =>
    ref.watch(historyRepositoryProvider).watchHistory(limit: limit);

/// 条目的最新进度（详情页“继续阅读”）。
@riverpod
Stream<ItemProgress?> itemProgress(Ref ref, String sourceId, String itemId) =>
    ref.watch(historyRepositoryProvider).watchLatestProgress(sourceId, itemId);

/// 条目下已读 unit 的 id 集合（详情页章节列表）。
@riverpod
Stream<Set<String>> readUnitIds(Ref ref, String sourceId, String itemId) =>
    ref.watch(historyRepositoryProvider).watchReadUnitIds(sourceId, itemId);
