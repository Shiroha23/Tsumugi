/// 声明式规则（source-spec §3.1）的类型化表示。
///
/// 只做结构校验；表达式本身的语法错误在求值时记录日志（§3.3）。
library;

import '../../encoding/text_decoding.dart';

/// `request` 对象。
class RequestRule {
  const RequestRule({
    required this.url,
    this.method = 'GET',
    this.body,
    this.headers = const {},
    this.charset,
  });

  factory RequestRule.fromJson(Object? json, String path) {
    final map = _map(json, path);
    final method = (_optString(map, 'method', path) ?? 'GET').toUpperCase();
    if (method != 'GET' && method != 'POST') {
      throw FormatException('$path.method 只能是 GET 或 POST: $method');
    }
    final charset = _optString(map, 'charset', path);
    if (charset != null && normalizeCharset(charset) == null) {
      throw FormatException('$path.charset 不是支持的字符集: $charset');
    }
    return RequestRule(
      url: _string(map, 'url', path),
      method: method,
      body: _optString(map, 'body', path),
      headers: _stringMap(map['headers'], '$path.headers'),
      charset: charset,
    );
  }

  final String url;
  final String method;
  final String? body;
  final Map<String, String> headers;

  /// 强制按此字符集解码响应（WHATWG 标签，如 `gbk`）；null 时自动识别（§5）。
  final String? charset;
}

/// 列表页规则：search 与 explore 的每个分类。
class ListRule {
  const ListRule({
    required this.request,
    required this.list,
    required this.fields,
    this.hasMore,
    this.name,
  });

  factory ListRule.fromJson(Object? json, String path, {bool named = false}) {
    final map = _map(json, path);
    return ListRule(
      name: named ? _string(map, 'name', path) : null,
      request: RequestRule.fromJson(map['request'], '$path.request'),
      list: _string(map, 'list', path),
      fields: _stringMap(map['fields'], '$path.fields'),
      hasMore: _optString(map, 'hasMore', path),
    );
  }

  final String? name;
  final RequestRule request;
  final String list;
  final Map<String, String> fields;
  final String? hasMore;
}

/// `detail.units`。
class UnitsRule {
  const UnitsRule({
    required this.list,
    required this.fields,
    this.reverse = false,
  });

  factory UnitsRule.fromJson(Object? json, String path) {
    final map = _map(json, path);
    final reverse = map['reverse'] ?? false;
    if (reverse is! bool) throw FormatException('$path.reverse 必须是布尔值');
    return UnitsRule(
      list: _string(map, 'list', path),
      fields: _stringMap(map['fields'], '$path.fields'),
      reverse: reverse,
    );
  }

  final String list;
  final Map<String, String> fields;
  final bool reverse;
}

class DetailRule {
  const DetailRule({required this.request, required this.fields, this.units});

  factory DetailRule.fromJson(Object? json, String path) {
    final map = _map(json, path);
    return DetailRule(
      request: map['request'] == null
          ? const RequestRule(url: '{{id}}')
          : RequestRule.fromJson(map['request'], '$path.request'),
      fields: _stringMap(map['fields'], '$path.fields'),
      units: map['units'] == null
          ? null
          : UnitsRule.fromJson(map['units'], '$path.units'),
    );
  }

  final RequestRule request;
  final Map<String, String> fields;
  final UnitsRule? units;
}

/// `content.subtitles`（source-spec §3.1「视频外挂字幕」）。
///
/// 简写（字符串）等价于 `list` 为该表达式、只取 `url` 的完整写法，见 [urls]。
class SubtitlesRule {
  const SubtitlesRule.urls(String this.urls)
    : list = null,
      fields = const {},
      charset = null;

  const SubtitlesRule.list({
    required String this.list,
    required this.fields,
    this.charset,
  }) : urls = null;

  factory SubtitlesRule.fromJson(Object? json, String path) {
    if (json is String) {
      if (json.trim().isEmpty) throw FormatException('$path 必须是非空字符串');
      return SubtitlesRule.urls(json);
    }
    if (json is! Map) throw FormatException('$path 必须是字符串或对象');
    final map = _map(json, path);
    final fields = _stringMap(map['fields'], '$path.fields');
    if (fields['url']?.trim().isNotEmpty != true) {
      throw FormatException('$path.fields.url 必须是非空字符串');
    }
    final charset = _optString(map, 'charset', path);
    if (charset != null && normalizeCharset(charset) == null) {
      throw FormatException('$path.charset 不是支持的字符集: $charset');
    }
    return SubtitlesRule.list(
      list: _string(map, 'list', path),
      fields: fields,
      charset: charset,
    );
  }

  /// 简写：多值表达式，每个值是一条字幕的 URL。
  final String? urls;

  /// 完整写法的列表节点表达式。
  final String? list;

  /// 完整写法：对每个列表节点求值的 `url` / `lang` / `format`。
  final Map<String, String> fields;

  /// 常量字符集标签（已校验），作用于本规则产出的全部字幕。
  final String? charset;

  Iterable<String> get expressions sync* {
    if (urls != null) yield urls!;
    if (list != null) yield list!;
    yield* fields.values;
  }
}

/// `content`：除 `request` 与 `subtitles` 外，其余键都是按媒体类型解释的表达式。
class ContentRule {
  const ContentRule({
    required this.request,
    required this.fields,
    this.subtitles,
  });

  factory ContentRule.fromJson(Object? json, String path) {
    final map = _map(json, path);
    return ContentRule(
      request: map['request'] == null
          ? const RequestRule(url: '{{unitId}}')
          : RequestRule.fromJson(map['request'], '$path.request'),
      subtitles: map['subtitles'] == null
          ? null
          : SubtitlesRule.fromJson(map['subtitles'], '$path.subtitles'),
      fields: _stringMap(
        {...map}
          ..remove('request')
          ..remove('subtitles'),
        path,
      ),
    );
  }

  final RequestRule request;
  final Map<String, String> fields;

  /// 视频外挂字幕；只有 `video` 类型使用。
  final SubtitlesRule? subtitles;
}

class DeclarativeRules {
  const DeclarativeRules({
    this.search,
    this.explore = const [],
    this.detail,
    this.content,
  });

  /// 解析 `rules`；结构错误时抛出 [FormatException]。
  factory DeclarativeRules.fromJson(Map<String, dynamic> json) {
    final explore = json['explore'];
    if (explore != null && explore is! List) {
      throw const FormatException('rules.explore 必须是数组');
    }
    return DeclarativeRules(
      search: json['search'] == null
          ? null
          : ListRule.fromJson(json['search'], 'rules.search'),
      explore: [
        for (final (i, e) in ((explore as List?) ?? const []).indexed)
          ListRule.fromJson(e, 'rules.explore[$i]', named: true),
      ],
      detail: json['detail'] == null
          ? null
          : DetailRule.fromJson(json['detail'], 'rules.detail'),
      content: json['content'] == null
          ? null
          : ContentRule.fromJson(json['content'], 'rules.content'),
    );
  }

  final ListRule? search;
  final List<ListRule> explore;
  final DetailRule? detail;
  final ContentRule? content;

  /// 规则中所有表达式（用于预先收集 `js:` 片段）。
  Iterable<String> get expressions sync* {
    for (final l in [?search, ...explore]) {
      yield l.list;
      yield* l.fields.values;
      if (l.hasMore != null) yield l.hasMore!;
    }
    if (detail case final d?) {
      yield* d.fields.values;
      if (d.units case final u?) {
        yield u.list;
        yield* u.fields.values;
      }
    }
    if (content case final c?) {
      yield* c.fields.values;
      if (c.subtitles case final s?) yield* s.expressions;
    }
  }
}

Map<String, Object?> _map(Object? json, String path) {
  if (json is Map<String, Object?>) return json;
  if (json is Map) return json.cast<String, Object?>();
  throw FormatException('$path 必须是对象');
}

String _string(Map<String, Object?> map, String key, String path) {
  final v = map[key];
  if (v is String && v.trim().isNotEmpty) return v;
  throw FormatException('$path.$key 必须是非空字符串');
}

String? _optString(Map<String, Object?> map, String key, String path) {
  final v = map[key];
  if (v == null || v is String) return v as String?;
  throw FormatException('$path.$key 必须是字符串');
}

Map<String, String> _stringMap(Object? json, String path) {
  if (json == null) return const {};
  final map = _map(json, path);
  return {
    for (final MapEntry(:key, :value) in map.entries)
      if (value != null)
        key: value is String
            ? value
            : throw FormatException('$path.$key 必须是字符串'),
  };
}
