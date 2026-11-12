import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'novel_reader_preferences.g.dart';

/// 阅读模式。
enum NovelReaderMode {
  /// 上下连续滚动。
  scroll,

  /// 左右翻页（按屏幕分页排版）。
  paged;

  String get label => switch (this) {
    scroll => '上下滚动',
    paged => '左右翻页',
  };
}

/// 配色主题。
enum NovelReaderTheme {
  light,
  dark,

  /// 护眼（米黄底）。
  sepia;

  String get label => switch (this) {
    light => '亮色',
    dark => '暗色',
    sepia => '护眼',
  };

  Color get background => switch (this) {
    light => const Color(0xFFFAFAFA),
    dark => const Color(0xFF1B1B1D),
    sepia => const Color(0xFFF3E9D2),
  };

  Color get foreground => switch (this) {
    light => const Color(0xFF222222),
    dark => const Color(0xFFBDBDBD),
    sepia => const Color(0xFF4A3B28),
  };

  Color get muted => foreground.withValues(alpha: 0.55);

  Brightness get brightness =>
      this == dark ? Brightness.dark : Brightness.light;
}

/// 字体（使用系统已安装的字体，按平台给出候选，找不到时回落到系统默认）。
enum NovelFont {
  system,
  serif,
  sans,
  mono;

  String get label => switch (this) {
    system => '系统默认',
    serif => '宋体 / 衬线',
    sans => '黑体 / 无衬线',
    mono => '等宽',
  };

  List<String>? get families => switch (this) {
    system => null,
    serif => const [
      'Songti SC',
      'SimSun',
      'Noto Serif CJK SC',
      'Source Han Serif SC',
      'serif',
    ],
    sans => const [
      'PingFang SC',
      'Microsoft YaHei',
      'Noto Sans CJK SC',
      'Source Han Sans SC',
      'sans-serif',
    ],
    mono => const ['Menlo', 'Consolas', 'Roboto Mono', 'monospace'],
  };
}

/// 小说阅读器偏好（全局）。
final class NovelReaderPreferences {
  const NovelReaderPreferences({
    this.mode = NovelReaderMode.scroll,
    this.fontSize = 18,
    this.lineHeight = 1.8,
    this.paragraphSpacing = 0.6,
    this.margin = 20,
    this.font = NovelFont.system,
    this.theme = NovelReaderTheme.light,
  });

  factory NovelReaderPreferences.fromJson(Map<String, dynamic> json) {
    double num_(String key, double fallback, double min, double max) =>
        ((json[key] as num?)?.toDouble() ?? fallback).clamp(min, max);
    return NovelReaderPreferences(
      mode:
          NovelReaderMode.values.asNameMap()[json['mode']] ??
          NovelReaderMode.scroll,
      fontSize: num_('fontSize', 18, minFontSize, maxFontSize),
      lineHeight: num_('lineHeight', 1.8, 1.2, 2.6),
      paragraphSpacing: num_('paragraphSpacing', 0.6, 0, 2),
      margin: num_('margin', 20, 4, 64),
      font: NovelFont.values.asNameMap()[json['font']] ?? NovelFont.system,
      theme:
          NovelReaderTheme.values.asNameMap()[json['theme']] ??
          NovelReaderTheme.light,
    );
  }

  static const minFontSize = 12.0;
  static const maxFontSize = 40.0;

  final NovelReaderMode mode;

  /// 正文字号（逻辑像素）。
  final double fontSize;

  /// 行高（字号的倍数）。
  final double lineHeight;

  /// 段落间距（字号的倍数）。
  final double paragraphSpacing;

  /// 左右页边距（逻辑像素）；上下边距按它推算。
  final double margin;
  final NovelFont font;
  final NovelReaderTheme theme;

  NovelReaderPreferences copyWith({
    NovelReaderMode? mode,
    double? fontSize,
    double? lineHeight,
    double? paragraphSpacing,
    double? margin,
    NovelFont? font,
    NovelReaderTheme? theme,
  }) => NovelReaderPreferences(
    mode: mode ?? this.mode,
    fontSize: fontSize ?? this.fontSize,
    lineHeight: lineHeight ?? this.lineHeight,
    paragraphSpacing: paragraphSpacing ?? this.paragraphSpacing,
    margin: margin ?? this.margin,
    font: font ?? this.font,
    theme: theme ?? this.theme,
  );

  Map<String, dynamic> toJson() => {
    'mode': mode.name,
    'fontSize': fontSize,
    'lineHeight': lineHeight,
    'paragraphSpacing': paragraphSpacing,
    'margin': margin,
    'font': font.name,
    'theme': theme.name,
  };

  /// 影响排版（分页）的部分是否相同。
  bool sameLayout(NovelReaderPreferences o) =>
      o.fontSize == fontSize &&
      o.lineHeight == lineHeight &&
      o.paragraphSpacing == paragraphSpacing &&
      o.margin == margin &&
      o.font == font;

  @override
  bool operator ==(Object other) =>
      other is NovelReaderPreferences &&
      other.mode == mode &&
      other.theme == theme &&
      sameLayout(other);

  @override
  int get hashCode => Object.hash(
    mode,
    fontSize,
    lineHeight,
    paragraphSpacing,
    margin,
    font,
    theme,
  );
}

/// 偏好的持久化。
abstract interface class NovelReaderPreferencesStore {
  Future<NovelReaderPreferences> load();
  Future<void> save(NovelReaderPreferences preferences);
}

/// 内存实现（测试用）。
class MemoryNovelReaderPreferencesStore implements NovelReaderPreferencesStore {
  MemoryNovelReaderPreferencesStore([
    this.value = const NovelReaderPreferences(),
  ]);

  NovelReaderPreferences value;

  @override
  Future<NovelReaderPreferences> load() async => value;

  @override
  Future<void> save(NovelReaderPreferences preferences) async =>
      value = preferences;
}

/// 应用支持目录下的 `novel_reader.json`。读取失败时回落到默认值。
class FileNovelReaderPreferencesStore implements NovelReaderPreferencesStore {
  FileNovelReaderPreferencesStore([Future<File> Function()? file])
    : _file = file ?? _defaultFile;

  final Future<File> Function() _file;

  static Future<File> _defaultFile() async => File(
    '${(await getApplicationSupportDirectory()).path}'
    '${Platform.pathSeparator}novel_reader.json',
  );

  @override
  Future<NovelReaderPreferences> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return const NovelReaderPreferences();
      return NovelReaderPreferences.fromJson(
        jsonDecode(await f.readAsString()) as Map<String, dynamic>,
      );
    } on Object {
      return const NovelReaderPreferences();
    }
  }

  @override
  Future<void> save(NovelReaderPreferences preferences) async {
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
NovelReaderPreferencesStore novelReaderPreferencesStore(Ref ref) =>
    FileNovelReaderPreferencesStore();

/// 当前小说阅读器偏好；修改会立即生效并写入 [novelReaderPreferencesStoreProvider]。
@Riverpod(keepAlive: true)
class NovelReaderSettings extends _$NovelReaderSettings {
  @override
  Future<NovelReaderPreferences> build() =>
      ref.watch(novelReaderPreferencesStoreProvider).load();

  Future<void> change(
    NovelReaderPreferences Function(NovelReaderPreferences) apply,
  ) {
    final next = apply(state.value ?? const NovelReaderPreferences());
    state = AsyncData(next);
    return ref.read(novelReaderPreferencesStoreProvider).save(next);
  }
}
