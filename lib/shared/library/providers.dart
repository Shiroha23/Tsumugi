import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../core/storage/app_database.dart';
import '../../sources/model/common.dart';
import 'library_repository.dart';

export 'library_item.dart';
export 'library_repository.dart';

part 'providers.g.dart';

@Riverpod(keepAlive: true)
LibraryRepository libraryRepository(Ref ref) =>
    LibraryRepository(ref.watch(appDatabaseProvider));

/// 书架列表，可按类型过滤（null 为全部）。
@riverpod
Stream<List<LibraryEntry>> libraryEntries(Ref ref, {MediaType? type}) =>
    ref.watch(libraryRepositoryProvider).watchEntries(type: type);

/// 条目是否在书架（详情页的“加入书架”按钮）。
@riverpod
Stream<bool> isInLibrary(Ref ref, String sourceId, String itemId) =>
    ref.watch(libraryRepositoryProvider).watchContains(sourceId, itemId);
