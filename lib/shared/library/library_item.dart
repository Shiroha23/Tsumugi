import 'package:flutter/foundation.dart';

import '../../sources/model/common.dart';

/// 书架与历史共用的条目快照：定位一个条目（[sourceId] + [itemId]）并携带展示用的元数据。
///
/// 通常由搜索结果或详情页构造：`LibraryItem.fromSearchItem(sourceId, type, item)`。
@immutable
class LibraryItem {
  const LibraryItem({
    required this.sourceId,
    required this.itemId,
    required this.title,
    required this.mediaType,
    this.cover,
    this.coverHeaders,
  });

  factory LibraryItem.fromSearchItem(
    String sourceId,
    MediaType mediaType,
    SearchItem item,
  ) => LibraryItem(
    sourceId: sourceId,
    itemId: item.id,
    title: item.title,
    mediaType: mediaType,
    cover: item.cover,
    coverHeaders: item.coverHeaders,
  );

  /// 清单 `id`。
  final String sourceId;

  /// `SearchItem.id`。
  final String itemId;

  final String title;
  final MediaType mediaType;
  final String? cover;
  final Headers? coverHeaders;

  @override
  bool operator ==(Object other) =>
      other is LibraryItem &&
      other.sourceId == sourceId &&
      other.itemId == itemId &&
      other.title == title &&
      other.mediaType == mediaType &&
      other.cover == cover &&
      mapEquals(other.coverHeaders, coverHeaders);

  @override
  int get hashCode => Object.hash(
    sourceId,
    itemId,
    title,
    mediaType,
    cover,
    coverHeaders == null
        ? null
        : Object.hashAllUnordered(
            coverHeaders!.entries.map((e) => Object.hash(e.key, e.value)),
          ),
  );

  @override
  String toString() => 'LibraryItem($sourceId, $itemId, $title)';
}

/// 把数据库中的 `MediaType.name` 解析回枚举；未知值（未来版本写入的类型）返回 null。
MediaType? parseMediaType(String name) {
  for (final t in MediaType.values) {
    if (t.name == name) return t;
  }
  return null;
}
