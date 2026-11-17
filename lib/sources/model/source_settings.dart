import 'manifest.dart';

/// 源设置（docs/source-spec.md §1.1）支持的控件类型。
enum SourceSettingType {
  select,
  switchType('switch'),
  text;

  const SourceSettingType([this._wire]);

  final String? _wire;

  /// 清单中的写法。
  String get wire => _wire ?? name;

  /// 未知类型返回 null（见 [SourceSettingX.kind]）。
  static SourceSettingType? parse(String type) {
    for (final t in values) {
      if (t.wire == type) return t;
    }
    return null;
  }
}

/// `text` 设置值的最大长度（UTF-16 码元）。
const maxSettingTextLength = 1024;

final _keyPattern = RegExp(r'^[A-Za-z0-9_]{1,64}$');

/// `text` 值中不允许的字符：C0 / C1 控制字符、DEL 与 U+2028 / U+2029。
final settingTextForbidden = RegExp('[\u0000-\u001F\u007F-\u009F  ]');

extension SourceSettingX on SourceSetting {
  /// 已知类型；未知类型（较新的规范）为 null：不显示，值始终取 `default`。
  SourceSettingType? get kind => SourceSettingType.parse(type);

  /// [value] 是否是此设置的合法值。未知类型一律不合法（不接受用户值）。
  bool accepts(Object? value) => switch (kind) {
    SourceSettingType.select => value is String && options.contains(value),
    SourceSettingType.switchType => value is bool,
    SourceSettingType.text =>
      value is String &&
          value.length <= maxSettingTextLength &&
          !value.contains(settingTextForbidden),
    null => false,
  };

  /// 用户未修改时的值：清单 `default`，缺省时按类型取 `options[0]` / `false` / `""`。
  Object? get effectiveDefault => switch (kind) {
    SourceSettingType.select => defaultValue ?? options.firstOrNull,
    SourceSettingType.switchType => defaultValue ?? false,
    SourceSettingType.text => defaultValue ?? '',
    null => defaultValue,
  };
}

/// 校验清单的 `settings`（由 [SourceManifest.validate] 调用），返回错误信息。
List<String> validateSettingDefinitions(List<SourceSetting> settings) {
  final errors = <String>[];
  final seen = <String>{};
  for (final s in settings) {
    final where = 'settings.${s.key}';
    if (!_keyPattern.hasMatch(s.key)) {
      errors.add('settings 的 key 只能包含 [A-Za-z0-9_]，长度 1–64: ${s.key}');
    } else if (!seen.add(s.key)) {
      errors.add('settings 的 key 重复: ${s.key}');
    }
    if (s.label.trim().isEmpty) errors.add('$where 的 label 不能为空');
    switch (s.kind) {
      case SourceSettingType.select:
        if (s.options.isEmpty) {
          errors.add('$where 为 select 时 options 不能为空');
        } else if (s.options.any((o) => o.isEmpty)) {
          errors.add('$where 的 options 不能包含空字符串');
        } else if (s.options.toSet().length != s.options.length) {
          errors.add('$where 的 options 不能重复');
        }
      case SourceSettingType.switchType || SourceSettingType.text || null:
    }
    final def = s.defaultValue;
    if (s.kind != null && def != null && !s.accepts(def)) {
      errors.add(switch (s.kind!) {
        SourceSettingType.select => '$where 的 default 不在 options 中: $def',
        SourceSettingType.switchType => '$where 的 default 必须是布尔值',
        SourceSettingType.text =>
          '$where 的 default 必须是不含控制字符、最长 $maxSettingTextLength 字符的字符串',
      });
    }
  }
  return errors;
}

/// 清单中未知类型的设置（导入时给出警告）。
List<SourceSetting> unknownTypeSettings(SourceManifest manifest) => [
  for (final s in manifest.settings)
    if (s.kind == null) s,
];

/// 可在「源设置」中显示的项（已知类型）。
List<SourceSetting> editableSettings(SourceManifest manifest) => [
  for (final s in manifest.settings)
    if (s.kind != null) s,
];

/// 只保留 [stored] 中对 [manifest] 仍然有效的值：键存在、类型已知且值合法。
///
/// 用于升级源时过滤旧值、写入前过滤，以及读取时兜底。给出 [previous]（升级前的清单）时，
/// 还丢弃与旧清单相比 `type` 变化的项（source-spec §1.1：同一 `key`、同一 `type`）。
Map<String, Object?> sanitizeSettingValues(
  SourceManifest manifest,
  Map<String, Object?> stored, {
  SourceManifest? previous,
}) {
  final oldTypes = previous == null
      ? null
      : {for (final s in previous.settings) s.key: s.type};
  return {
    for (final s in manifest.settings)
      if (stored.containsKey(s.key) &&
          s.accepts(stored[s.key]) &&
          (oldTypes == null || oldTypes[s.key] == s.type))
        s.key: stored[s.key],
  };
}

/// 每个设置项的有效值：保存的有效值，否则 [SourceSettingX.effectiveDefault]。
Map<String, Object?> effectiveSettings(
  SourceManifest manifest,
  Map<String, Object?> stored,
) {
  final valid = sanitizeSettingValues(manifest, stored);
  return {
    for (final s in manifest.settings)
      s.key: valid.containsKey(s.key) ? valid[s.key] : s.effectiveDefault,
  };
}
