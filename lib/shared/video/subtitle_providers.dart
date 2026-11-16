import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/network/network_exception.dart';
import '../../core/subtitle/subtitle_loader.dart';
import '../../core/subtitle/subtitle_parser.dart';
import '../../sources/model/content.dart';
import '../../sources/network_error_mapping.dart';
import '../../sources/registry/providers.dart';
import '../../sources/source.dart';
import 'media_proxy_providers.dart';

export '../../core/subtitle/subtitle_parser.dart'
    show SubtitleCue, SubtitleDocument, SubtitleFormat, SubtitleFormatException;

/// 字幕加载失败的提示文字。
String subtitleErrorMessage(Object e) => switch (e) {
  SubtitleFormatException(:final message) => message,
  NetworkException() => e.toSourceException().message ?? e.kind.name,
  SourceException(:final message) => message ?? e.code.name,
  _ => '$e',
};

/// 取回并解析某个源的外挂字幕（architecture §6.4.7）：用与媒体代理相同的方式为该源新建客户端
/// （该源的 `SourceSession`：Cookie、UA、令牌桶），请求走 `source` 通道；不经本地代理、不交给播放器。
/// 相对地址基于清单的 `baseUrl` 解析。失败时抛 `NetworkException` / [SubtitleFormatException] /
/// [SourceException]。
final loadSubtitleProvider =
    Provider<
      Future<SubtitleDocument> Function(String sourceId, SubtitleRef subtitle)
    >(
      (ref) => (sourceId, subtitle) async {
        final installed = await ref.read(sourceRegistryProvider).get(sourceId);
        final manifest = installed?.manifest;
        if (installed == null || manifest == null) {
          throw SourceException(
            SourceErrorCode.unsupported,
            installed == null ? '源未安装：$sourceId' : '源清单不可用：$sourceId',
          );
        }
        final String url;
        try {
          url = Uri.parse(manifest.baseUrl)
              .resolve(subtitle.url.trim())
              .toString();
        } on FormatException {
          throw SourceException(SourceErrorCode.parse, '无效的字幕地址');
        }
        final client = ref.read(mediaProxyClientProvider)(manifest);
        try {
          return await fetchSubtitle(
            client,
            url,
            format: subtitle.format,
            charset: subtitle.charset,
            log: (m) => debugPrint('[subtitle] $m'),
          );
        } finally {
          client.close();
        }
      },
    );

/// 按源记住的字幕选择（architecture §5.2「字幕」）。
sealed class SubtitlePreference {
  const SubtitlePreference();

  static SubtitlePreference? fromJson(Object? json) => switch (json) {
    {'off': true} => const SubtitleOff(),
    {'label': final String label} => SubtitleLabel(label),
    _ => null,
  };

  Map<String, Object> toJson();
}

/// 关闭字幕。
class SubtitleOff extends SubtitlePreference {
  const SubtitleOff();

  @override
  Map<String, Object> toJson() => {'off': true};

  @override
  bool operator ==(Object other) => other is SubtitleOff;

  @override
  int get hashCode => 0;
}

/// 选择标签为 [label] 的字幕（外挂字幕的 `lang`，或内嵌轨的名称 / 语言）。
class SubtitleLabel extends SubtitlePreference {
  const SubtitleLabel(this.label);

  final String label;

  @override
  Map<String, Object> toJson() => {'label': label};

  @override
  bool operator ==(Object other) =>
      other is SubtitleLabel && other.label == label;

  @override
  int get hashCode => label.hashCode;
}

/// 按源保存字幕选择。
abstract interface class SubtitlePreferencesStore {
  Future<SubtitlePreference?> load(String sourceId);
  Future<void> save(String sourceId, SubtitlePreference preference);
}

/// 内存中的实现（测试用）。
class MemorySubtitlePreferencesStore implements SubtitlePreferencesStore {
  final values = <String, SubtitlePreference>{};

  @override
  Future<SubtitlePreference?> load(String sourceId) async => values[sourceId];

  @override
  Future<void> save(String sourceId, SubtitlePreference preference) async =>
      values[sourceId] = preference;
}

/// 应用支持目录下的 `video_subtitles.json`（`{源 id: {"off": true} | {"label": "…"}}`）。
/// 读取失败时视为没有记录，写入失败不影响播放。
class FileSubtitlePreferencesStore implements SubtitlePreferencesStore {
  FileSubtitlePreferencesStore([Future<File> Function()? file])
    : _file = file ?? _defaultFile;

  final Future<File> Function() _file;

  static Future<File> _defaultFile() async => File(
    '${(await getApplicationSupportDirectory()).path}'
    '${Platform.pathSeparator}video_subtitles.json',
  );

  Future<Map<String, Object?>> _read() async {
    try {
      final f = await _file();
      if (!await f.exists()) return {};
      final json = jsonDecode(await f.readAsString());
      return json is Map<String, Object?> ? json : {};
    } on Object {
      return {};
    }
  }

  @override
  Future<SubtitlePreference?> load(String sourceId) async =>
      SubtitlePreference.fromJson((await _read())[sourceId]);

  @override
  Future<void> save(String sourceId, SubtitlePreference preference) async {
    final all = await _read();
    all[sourceId] = preference.toJson();
    try {
      final f = await _file();
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode(all), flush: true);
    } on FileSystemException {
      // 偏好写入失败不影响播放。
    }
  }
}

final subtitlePreferencesStoreProvider = Provider<SubtitlePreferencesStore>(
  (ref) => FileSubtitlePreferencesStore(),
);
