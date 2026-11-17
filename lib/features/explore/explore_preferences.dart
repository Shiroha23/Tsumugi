import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'explore_preferences.g.dart';

/// 发现页上次选择的源与分类。
@immutable
final class ExploreSelection {
  const ExploreSelection({this.sourceId, this.categoryId});

  factory ExploreSelection.fromJson(Map<String, dynamic> json) =>
      ExploreSelection(
        sourceId: json['sourceId'] as String?,
        categoryId: json['categoryId'] as String?,
      );

  final String? sourceId;
  final String? categoryId;

  Map<String, dynamic> toJson() => {
    'sourceId': ?sourceId,
    'categoryId': ?categoryId,
  };

  @override
  bool operator ==(Object other) =>
      other is ExploreSelection &&
      other.sourceId == sourceId &&
      other.categoryId == categoryId;

  @override
  int get hashCode => Object.hash(sourceId, categoryId);

  @override
  String toString() => 'ExploreSelection($sourceId, $categoryId)';
}

/// [ExploreSelection] 的持久化。
abstract interface class ExplorePreferencesStore {
  Future<ExploreSelection> load();
  Future<void> save(ExploreSelection selection);
}

/// 内存实现（测试用）。
class MemoryExplorePreferencesStore implements ExplorePreferencesStore {
  MemoryExplorePreferencesStore([this.value = const ExploreSelection()]);

  ExploreSelection value;

  @override
  Future<ExploreSelection> load() async => value;

  @override
  Future<void> save(ExploreSelection selection) async => value = selection;
}

/// 应用支持目录下的 `explore.json`。读写失败时回落到“未选择”，不影响浏览。
class FileExplorePreferencesStore implements ExplorePreferencesStore {
  FileExplorePreferencesStore([Future<File> Function()? file])
    : _file = file ?? _defaultFile;

  final Future<File> Function() _file;

  static Future<File> _defaultFile() async => File(
    '${(await getApplicationSupportDirectory()).path}'
    '${Platform.pathSeparator}explore.json',
  );

  @override
  Future<ExploreSelection> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return const ExploreSelection();
      return ExploreSelection.fromJson(
        jsonDecode(await f.readAsString()) as Map<String, dynamic>,
      );
    } on Object {
      return const ExploreSelection();
    }
  }

  @override
  Future<void> save(ExploreSelection selection) async {
    try {
      final f = await _file();
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode(selection.toJson()), flush: true);
    } on Object {
      // 写入失败只是下次不能恢复选择。
    }
  }
}

@Riverpod(keepAlive: true)
ExplorePreferencesStore explorePreferencesStore(Ref ref) =>
    FileExplorePreferencesStore();
