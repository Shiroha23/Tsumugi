import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:json_path/json_path.dart';

import 'expression.dart';
import 'html_xpath.dart';
import 'js_evaluator.dart';

/// 调试日志回调。表达式求值失败不会抛出，只经由这里记录（source-spec §3.3）。
typedef DebugLog = void Function(String message);

void _noLog(String _) {}

/// 一份响应文档：原始文本，以及按需解析的 HTML / JSON 视图。
///
/// 作为表达式的初始输入时，各引擎取自己需要的视图：
/// css / xpath 用 HTML，json 用 JSON，regex / js 用原始文本。
class SourceDocument {
  SourceDocument(this.text);

  final String text;

  dom.Document? _html;
  Object? _json;
  bool _jsonParsed = false;

  dom.Document get html => _html ??= html_parser.parse(text);

  /// 解析失败时抛出 [FormatException]。
  Object? get json {
    if (!_jsonParsed) {
      _json = jsonDecode(text);
      _jsonParsed = true;
    }
    return _json;
  }
}

/// 选择器表达式求值器（source-spec §3.3）。
///
/// 输入可以是 [SourceDocument]、HTML 节点（[dom.Node]）、字符串或 JSON 值；
/// 列表规则（`list`）产出的每一项可直接作为字段表达式的输入。
///
/// 任何失败（语法错误、选择器非法、输入类型不符、JS 异常）都只记录日志，
/// 并把该管道视为空值，从而触发 `||` 回退。
class ExpressionEngine {
  ExpressionEngine({this.js, DebugLog? log}) : _log = log ?? _noLog;

  /// `js:` 步骤的执行器；为 `null` 时 `js:` 步骤一律为空值。
  final JsEvaluator? js;
  final DebugLog _log;

  final _parsed = <String, Expression?>{};
  final _jsonPaths = <String, JsonPath>{};
  final _xpath = HtmlXPath();

  /// 解析（并缓存）表达式；语法错误时记录日志并返回 `null`。
  Expression? parse(String source) {
    if (_parsed.containsKey(source)) return _parsed[source];
    Expression? expr;
    try {
      expr = Expression.parse(source);
    } on FormatException catch (e) {
      _log('表达式语法错误 `$source`: ${e.message}');
    }
    return _parsed[source] = expr;
  }

  /// 取单个字符串值；为空时返回 `null`。
  Future<String?> string(String? source, Object? input) async {
    for (final v in await values(source, input)) {
      final s = stringify(v);
      if (s != null && s.isNotEmpty) return s;
    }
    return null;
  }

  /// 取全部非空字符串值（无论表达式是否带 `[]`）。
  Future<List<String>> strings(String? source, Object? input) async => [
    for (final v in await values(source, input))
      if (stringify(v) case final s? when s.isNotEmpty) s,
  ];

  /// 取列表节点（用于 `list` 规则）：最后一步总是取全部匹配，且不做默认提取，
  /// 结果可作为字段表达式的输入。
  Future<List<Object>> nodes(String? source, Object? input) async => [
    for (final v in await values(source, input, nodes: true)) ?v,
  ];

  /// 结果是否非空（用于 `hasMore`）。字符串 `false` / `0` 视为假。
  Future<bool> truthy(String? source, Object? input) async {
    final s = await strings(source, input);
    if (s.isEmpty) return false;
    final first = s.first.toLowerCase();
    return !(s.length == 1 && (first == 'false' || first == '0'));
  }

  /// 原始求值结果。未带 `[]` 时至多一个元素。
  Future<List<Object?>> values(
    String? source,
    Object? input, {
    bool nodes = false,
  }) async {
    if (source == null || input == null) return const [];
    final expr = parse(source);
    if (expr == null) return const [];
    for (final pipeline in expr.alternatives) {
      final result = await _runPipeline(expr, pipeline, input, nodes);
      if (nodes ? result.isNotEmpty : !_isEmpty(result)) return result;
    }
    return const [];
  }

  bool _isEmpty(List<Object?> values) => values.every((v) {
    final s = stringify(v);
    return s == null || s.isEmpty;
  });

  Future<List<Object?>> _runPipeline(
    Expression expr,
    Pipeline pipeline,
    Object input,
    bool nodes,
  ) async {
    var values = <Object?>[input];
    var multi = false;
    for (var i = 0; i < pipeline.steps.length; i++) {
      final step = pipeline.steps[i];
      final last = i == pipeline.steps.length - 1;
      try {
        if (step.engine == SelectorEngine.js) {
          final evaluator = js;
          if (evaluator == null) {
            throw StateError('此源未启用 js 求值');
          }
          final arg = multi
              ? [for (final v in values) _toJs(v)]
              : (values.isEmpty ? null : _toJs(values.first));
          final r = await evaluator.evaluate(step.selector, arg);
          if (r is List) {
            values = r;
            multi = true;
          } else {
            values = r == null ? [] : [r];
          }
        } else {
          final all = step.multi || (nodes && last);
          final out = <Object?>[];
          for (final v in values) {
            if (v == null) continue;
            final matches = _apply(step, v, all: all);
            final extracted = _extract(step, matches, defaults: last && !nodes);
            out.addAll(all ? extracted : extracted.take(1));
          }
          values = out;
          multi = multi || all;
        }
      } on Object catch (e) {
        _log('表达式 `${expr.source}` 的步骤 `$step` 求值失败: $e');
        return const [];
      }
      if (values.isEmpty) return const [];
    }
    return multi ? values : values.take(1).toList();
  }

  List<Object> _apply(Step step, Object input, {required bool all}) {
    switch (step.engine) {
      case SelectorEngine.css:
        final node = _asHtml(input);
        if (all) return _querySelectorAll(node, step.selector);
        final first = _querySelector(node, step.selector);
        return first == null ? const [] : [first];
      case SelectorEngine.xpath:
        return _xpath.evaluate(_asHtml(input), step.selector);
      case SelectorEngine.json:
        final path = _jsonPaths[step.selector] ??= JsonPath(step.selector);
        return [for (final m in path.read(_asJson(input))) ?m.value];
      case SelectorEngine.regex:
        final group = switch (step.extract) {
          GroupExtract(:final group) => group,
          _ => 0,
        };
        final re = RegExp(step.selector);
        final text = _asText(input);
        final matches = all ? re.allMatches(text) : [?re.firstMatch(text)];
        return [
          for (final m in matches)
            if (group <= m.groupCount) ?m.group(group),
        ];
      case SelectorEngine.js:
        throw StateError('unreachable');
    }
  }

  /// 应用 `@` 提取。没有显式提取时：最终步骤用默认的文本提取，中间步骤保留原节点。
  List<Object> _extract(
    Step step,
    List<Object> matches, {
    required bool defaults,
  }) {
    final extract = step.extract;
    if (extract == null || extract is GroupExtract) {
      return defaults ? [for (final m in matches) ?stringify(m)] : matches;
    }
    return [for (final m in matches) ?_extractOne(extract, m)];
  }

  String? _extractOne(Extract extract, Object node) => switch (extract) {
    TextExtract() => stringify(node),
    HtmlExtract() => switch (node) {
      dom.Element() => node.innerHtml.trim(),
      dom.Document() => node.outerHtml,
      _ => stringify(node),
    },
    OuterHtmlExtract() => switch (node) {
      dom.Element() => node.outerHtml,
      dom.Document() => node.outerHtml,
      _ => stringify(node),
    },
    AttrExtract(:final name) => switch (node) {
      dom.Element() => node.attributes[name]?.trim(),
      _ => null,
    },
    GroupExtract() => stringify(node),
  };

  dom.Node _asHtml(Object input) => switch (input) {
    SourceDocument() => input.html,
    dom.Node() => input,
    String() => html_parser.parse(input),
    _ => throw FormatException('需要 HTML 输入，实际为 ${input.runtimeType}'),
  };

  Object? _asJson(Object input) => switch (input) {
    SourceDocument() => input.json,
    String() => jsonDecode(input),
    dom.Node() => throw const FormatException('需要 JSON 输入，实际为 HTML 节点'),
    _ => input,
  };

  String _asText(Object input) => switch (input) {
    SourceDocument() => input.text,
    String() => input,
    dom.Element() => input.outerHtml,
    dom.Document() => input.outerHtml,
    dom.Node() => input.text ?? '',
    _ => jsonEncode(input),
  };

  Object? _toJs(Object? v) => switch (v) {
    SourceDocument() => v.text,
    dom.Node() => stringify(v),
    _ => v,
  };

  static List<dom.Element> _querySelectorAll(dom.Node node, String sel) =>
      switch (node) {
        dom.Document() => node.querySelectorAll(sel),
        dom.DocumentFragment() => node.querySelectorAll(sel),
        dom.Element() => node.querySelectorAll(sel),
        _ => const [],
      };

  static dom.Element? _querySelector(dom.Node node, String sel) =>
      switch (node) {
        dom.Document() => node.querySelector(sel),
        dom.DocumentFragment() => node.querySelector(sel),
        dom.Element() => node.querySelector(sel),
        _ => null,
      };

  /// 把任意结果值转成字符串：节点取文本（去首尾空白），JSON 对象 / 数组序列化。
  static String? stringify(Object? v) => switch (v) {
    null => null,
    String() => v.trim(),
    SourceDocument() => v.text.trim(),
    dom.Document() => v.documentElement?.text.trim(),
    dom.Node() => v.text?.trim(),
    num() || bool() => v.toString(),
    _ => jsonEncode(v),
  };
}
