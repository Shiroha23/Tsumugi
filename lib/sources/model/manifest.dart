import 'package:freezed_annotation/freezed_annotation.dart';

import 'common.dart';

part 'manifest.freezed.dart';
part 'manifest.g.dart';

/// 客户端当前支持的源规范版本。
const supportedApiVersions = {1};

@freezed
abstract class RateLimit with _$RateLimit {
  const factory RateLimit({required int requests, required int perSeconds}) =
      _RateLimit;

  factory RateLimit.fromJson(Map<String, dynamic> json) =>
      _$RateLimitFromJson(json);
}

@freezed
abstract class SourceSetting with _$SourceSetting {
  const factory SourceSetting({
    required String key,
    required String label,
    required String type, // select | text | switch
    @Default([]) List<String> options,
    @JsonKey(name: 'default') Object? defaultValue,
  }) = _SourceSetting;

  factory SourceSetting.fromJson(Map<String, dynamic> json) =>
      _$SourceSettingFromJson(json);
}

/// 源清单（docs/source-spec.md §1）。
@freezed
abstract class SourceManifest with _$SourceManifest {
  const SourceManifest._();

  const factory SourceManifest({
    required int apiVersion,
    required String id,
    required String name,
    required MediaType type,
    required String version,
    required String baseUrl,
    required SourceEngine engine,
    String? author,
    String? description,
    String? lang,
    @Default(false) bool nsfw,
    String? icon,
    @Default([]) List<String> allowedHosts,
    @Default({}) Headers headers,
    RateLimit? rateLimit,
    @Default(15000) int timeoutMs,
    @Default([]) List<SourceSetting> settings,
    Map<String, dynamic>? rules,
    String? script,
  }) = _SourceManifest;

  factory SourceManifest.fromJson(Map<String, dynamic> json) =>
      _$SourceManifestFromJson(json);

  static final _idPattern = RegExp(r'^[a-z0-9._-]+$');

  /// 返回所有校验错误；为空表示通过。
  List<String> validate() {
    final errors = <String>[];
    if (!supportedApiVersions.contains(apiVersion)) {
      errors.add('不支持的 apiVersion: $apiVersion');
    }
    if (!_idPattern.hasMatch(id)) errors.add('id 只能包含 [a-z0-9._-]: $id');
    if (name.trim().isEmpty) errors.add('name 不能为空');
    final base = Uri.tryParse(baseUrl);
    if (base == null ||
        !(base.isScheme('http') || base.isScheme('https')) ||
        base.host.isEmpty) {
      errors.add('baseUrl 必须是 http(s) 绝对地址: $baseUrl');
    }
    switch (engine) {
      case SourceEngine.declarative when rules == null:
        errors.add('engine=declarative 时必须提供 rules');
      case SourceEngine.script when script == null || script!.trim().isEmpty:
        errors.add('engine=script 时必须提供 script');
      default:
    }
    return errors;
  }
}
