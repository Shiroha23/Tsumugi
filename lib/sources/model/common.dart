import 'package:freezed_annotation/freezed_annotation.dart';

part 'common.freezed.dart';
part 'common.g.dart';

/// 源支持的媒体类型。
enum MediaType { comic, novel, video, music }

/// 源引擎类型。
enum SourceEngine { declarative, script }

/// 连载状态。
enum SeriesStatus { ongoing, completed, unknown }

typedef Headers = Map<String, String>;

/// 分页结果。`T` 的反序列化由调用方提供。
class PageResult<T> {
  const PageResult({required this.items, required this.hasMore});

  factory PageResult.fromJson(
    Map<String, dynamic> json,
    T Function(Map<String, dynamic>) fromItem,
  ) => PageResult(
    items: [
      for (final e in (json['items'] as List? ?? const []))
        fromItem(e as Map<String, dynamic>),
    ],
    hasMore: json['hasMore'] as bool? ?? false,
  );

  final List<T> items;
  final bool hasMore;
}

@freezed
abstract class SearchItem with _$SearchItem {
  const factory SearchItem({
    required String id,
    required String title,
    String? cover,
    Headers? coverHeaders,
    String? subtitle,
    @Default([]) List<String> tags,
  }) = _SearchItem;

  factory SearchItem.fromJson(Map<String, dynamic> json) =>
      _$SearchItemFromJson(json);
}

/// 章节 / 剧集 / 曲目的统一抽象。
@freezed
abstract class Unit with _$Unit {
  const factory Unit({
    required String id,
    required String title,
    int? index,
    String? updatedAt,
  }) = _Unit;

  factory Unit.fromJson(Map<String, dynamic> json) => _$UnitFromJson(json);
}

@freezed
abstract class UnitGroup with _$UnitGroup {
  const factory UnitGroup({
    required String name,
    @Default([]) List<Unit> units,
  }) = _UnitGroup;

  factory UnitGroup.fromJson(Map<String, dynamic> json) =>
      _$UnitGroupFromJson(json);
}

@freezed
abstract class Detail with _$Detail {
  const factory Detail({
    required String id,
    required String title,
    String? cover,
    String? author,
    String? description,
    @Default([]) List<String> tags,
    @JsonKey(unknownEnumValue: SeriesStatus.unknown)
    @Default(SeriesStatus.unknown)
    SeriesStatus status,
    String? updatedAt,
    @Default([]) List<Unit> units,
    List<UnitGroup>? groups,
  }) = _Detail;

  factory Detail.fromJson(Map<String, dynamic> json) => _$DetailFromJson(json);
}

@freezed
abstract class ExploreCategory with _$ExploreCategory {
  const factory ExploreCategory({required String id, required String name}) =
      _ExploreCategory;

  factory ExploreCategory.fromJson(Map<String, dynamic> json) =>
      _$ExploreCategoryFromJson(json);
}
