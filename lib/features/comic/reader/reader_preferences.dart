import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'reader_preferences.g.dart';

/// 阅读模式。
enum ReaderMode {
  /// 纵向连续滚动（条漫）。
  vertical,

  /// 横向翻页，从左往右。
  leftToRight,

  /// 横向翻页，从右往左（日漫）。
  rightToLeft;

  bool get isPaged => this != vertical;

  String get label => switch (this) {
    vertical => '纵向滚动',
    leftToRight => '左→右翻页',
    rightToLeft => '右→左翻页',
  };
}

/// 阅读器偏好（全局）。
final class ReaderPreferences {
  const ReaderPreferences({
    this.mode = ReaderMode.vertical,
    this.autoNextChapter = true,
    this.preloadPages = 3,
  });

  factory ReaderPreferences.fromJson(Map<String, dynamic> json) =>
      ReaderPreferences(
        mode:
            ReaderMode.values.asNameMap()[json['mode']] ?? ReaderMode.vertical,
        autoNextChapter: json['autoNextChapter'] as bool? ?? true,
        preloadPages: (json['preloadPages'] as num?)?.toInt().clamp(0, 10) ?? 3,
      );

  final ReaderMode mode;

  /// 读到末尾后继续翻页 / 滚动时直接进入下一章；为 false 时需点击“下一章”。
  final bool autoNextChapter;

  /// 预加载当前页之后的页数。
  final int preloadPages;

  ReaderPreferences copyWith({
    ReaderMode? mode,
    bool? autoNextChapter,
    int? preloadPages,
  }) => ReaderPreferences(
    mode: mode ?? this.mode,
    autoNextChapter: autoNextChapter ?? this.autoNextChapter,
    preloadPages: preloadPages ?? this.preloadPages,
  );

  Map<String, dynamic> toJson() => {
    'mode': mode.name,
    'autoNextChapter': autoNextChapter,
    'preloadPages': preloadPages,
  };

  @override
  bool operator ==(Object other) =>
      other is ReaderPreferences &&
      other.mode == mode &&
      other.autoNextChapter == autoNextChapter &&
      other.preloadPages == preloadPages;

  @override
  int get hashCode => Object.hash(mode, autoNextChapter, preloadPages);
}

/// 偏好的持久化。
abstract interface class ReaderPreferencesStore {
  Future<ReaderPreferences> load();
  Future<void> save(ReaderPreferences preferences);
}

/// 内存实现（测试用）。
class MemoryReaderPreferencesStore implements ReaderPreferencesStore {
  MemoryReaderPreferencesStore([this.value = const ReaderPreferences()]);

  ReaderPreferences value;

  @override
  Future<ReaderPreferences> load() async => value;

  @override
  Future<void> save(ReaderPreferences preferences) async => value = preferences;
}

/// 应用支持目录下的 `comic_reader.json`。读取失败时回落到默认值。
class FileReaderPreferencesStore implements ReaderPreferencesStore {
  FileReaderPreferencesStore([Future<File> Function()? file])
    : _file = file ?? _defaultFile;

  final Future<File> Function() _file;

  static Future<File> _defaultFile() async => File(
    '${(await getApplicationSupportDirectory()).path}'
    '${Platform.pathSeparator}comic_reader.json',
  );

  @override
  Future<ReaderPreferences> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return const ReaderPreferences();
      return ReaderPreferences.fromJson(
        jsonDecode(await f.readAsString()) as Map<String, dynamic>,
      );
    } on Object {
      return const ReaderPreferences();
    }
  }

  @override
  Future<void> save(ReaderPreferences preferences) async {
    try {
      final f = await _file();
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode(preferences.toJson()), flush: true);
    } on FileSystemException {
      // 偏好写入失败不影响阅读。
    }
  }
}

@Riverpod(keepAlive: true)
ReaderPreferencesStore readerPreferencesStore(Ref ref) =>
    FileReaderPreferencesStore();

/// 当前阅读器偏好；修改会立即生效并写入 [readerPreferencesStoreProvider]。
@Riverpod(keepAlive: true)
class ReaderSettings extends _$ReaderSettings {
  @override
  Future<ReaderPreferences> build() =>
      ref.watch(readerPreferencesStoreProvider).load();

  Future<void> change(ReaderPreferences Function(ReaderPreferences) apply) {
    final next = apply(state.value ?? const ReaderPreferences());
    state = AsyncData(next);
    return ref.read(readerPreferencesStoreProvider).save(next);
  }

  Future<void> setMode(ReaderMode mode) =>
      change((p) => p.copyWith(mode: mode));
}
