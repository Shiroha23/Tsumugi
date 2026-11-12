import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../../expression/html_xpath.dart';
import '../script_runtime.dart';

/// `tsumugi.html` 的 worker 侧实现：DOM 留在 worker isolate 的 Dart 堆里，
/// 脚本只拿到整数句柄，JS prelude 再把句柄包装成 `HtmlNode` 对象
/// （句柄协议见 docs/source-spec.md §4.2.1）。
///
/// 句柄只在本次入口调用内有效：[reset] 在每次调用结束后清空全部 DOM。
/// 为防止 Dart 侧内存不受 JS 堆上限约束地增长，单次调用内的句柄数与解析的文本总量有上限，
/// 超出 → `E_LIMIT`。
class HtmlHandles {
  HtmlHandles({this.maxHandles = 200000, this.maxParsedChars = 64 << 20});

  final int maxHandles;
  final int maxParsedChars;

  final _nodes = <int, dom.Node>{};
  final _ids = Map<dom.Node, int>.identity();
  final _bases = Expando<Uri>('html-base');
  final _xpath = HtmlXPath();
  var _next = 1;
  var _parsedChars = 0;

  /// 当前存活的句柄数（测试用）。
  int get length => _nodes.length;

  void reset() {
    _nodes.clear();
    _ids.clear();
    _next = 1;
    _parsedChars = 0;
  }

  /// 供 [WorkerHost.functions] 使用的函数表（内部路径，不直接暴露给脚本）。
  Map<String, HostFunction> functions({required Uri defaultBase}) => {
    'html.parse': (a) => parse(_str(a, 0), _optStr(a, 1), defaultBase),
    'html.select': (a) => [
      for (final e in _queryAll(_node(a), _str(a, 1))) _id(e),
    ],
    'html.selectFirst': (a) => switch (_query(_node(a), _str(a, 1))) {
      final e? => _id(e),
      null => null,
    },
    'html.xpath': (a) => [
      for (final r in _xpath.evaluate(_node(a), _str(a, 1)))
        _id(r is dom.Node ? r : dom.Text(r as String)),
    ],
    'html.text': (a) => _text(_node(a)),
    'html.html': (a) => switch (_node(a)) {
      dom.Element(:final innerHtml) => innerHtml,
      dom.Document(:final outerHtml) => outerHtml,
      final n => _text(n),
    },
    'html.outerHtml': (a) => switch (_node(a)) {
      dom.Element(:final outerHtml) => outerHtml,
      dom.Document(:final outerHtml) => outerHtml,
      final n => _text(n),
    },
    'html.attr': (a) => _attr(_node(a), _str(a, 1)),
    'html.absUrl': (a) {
      final node = _node(a);
      final value = _attr(node, _str(a, 1))?.trim();
      if (value == null || value.isEmpty) return null;
      final base = _bases[_root(node)] ?? defaultBase;
      final resolved = Uri.tryParse(value);
      return resolved == null ? null : base.resolveUri(resolved).toString();
    },
  };

  int parse(String text, String? baseUrl, Uri defaultBase) {
    _parsedChars += text.length;
    if (_parsedChars > maxParsedChars) {
      throw ScriptException(
        'html.parse: more than $maxParsedChars characters parsed in one call.',
        code: ScriptException.limit,
      );
    }
    final doc = html_parser.parse(text);
    if (baseUrl != null) {
      final parsed = Uri.tryParse(baseUrl);
      if (parsed == null || !parsed.hasScheme) {
        throw ScriptException('html.parse: invalid baseUrl "$baseUrl".');
      }
      _bases[doc] = parsed;
    }
    return _id(doc);
  }

  int _id(dom.Node node) {
    final existing = _ids[node];
    if (existing != null) return existing;
    if (_nodes.length >= maxHandles) {
      throw ScriptException(
        'Too many HtmlNode handles in one call (max $maxHandles).',
        code: ScriptException.limit,
      );
    }
    final id = _next++;
    _nodes[id] = node;
    _ids[node] = id;
    return id;
  }

  dom.Node _node(List<Object?> args) {
    final h = args.isEmpty ? null : args[0];
    final node = h is int ? _nodes[h] : null;
    if (node == null) {
      throw const ScriptException(
        'HtmlNode is no longer valid (nodes only live for one call).',
      );
    }
    return node;
  }

  static String _str(List<Object?> args, int i) {
    final v = i < args.length ? args[i] : null;
    if (v is! String) {
      throw ScriptException('Argument ${i + 1} must be a string.');
    }
    return v;
  }

  static String? _optStr(List<Object?> args, int i) {
    final v = i < args.length ? args[i] : null;
    if (v == null) return null;
    if (v is! String) {
      throw ScriptException('Argument ${i + 1} must be a string.');
    }
    return v;
  }

  static String _text(dom.Node node) => switch (node) {
    dom.Document() => node.documentElement?.text.trim() ?? '',
    _ => (node.text ?? '').trim(),
  };

  static String? _attr(dom.Node node, String name) =>
      node is dom.Element ? node.attributes[name] : null;

  static dom.Node _root(dom.Node node) {
    var n = node;
    while (n.parentNode != null) {
      n = n.parentNode!;
    }
    return n;
  }

  static List<dom.Element> _queryAll(dom.Node node, String css) =>
      switch (node) {
        dom.Document() => node.querySelectorAll(css),
        dom.DocumentFragment() => node.querySelectorAll(css),
        dom.Element() => node.querySelectorAll(css),
        _ => const [],
      };

  static dom.Element? _query(dom.Node node, String css) => switch (node) {
    dom.Document() => node.querySelector(css),
    dom.DocumentFragment() => node.querySelector(css),
    dom.Element() => node.querySelector(css),
    _ => null,
  };
}
