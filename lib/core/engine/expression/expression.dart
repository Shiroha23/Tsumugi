/// 选择器表达式的语法树与解析器（docs/source-spec.md §3.3）。
///
/// 语法：
///
/// ```text
/// expression := pipeline ( '||' pipeline )*        // 回退：左侧为空时取右侧
/// pipeline   := step ( '|>' step )*                // 管道：左侧结果作为右侧输入
/// step       := engine ':' selector [ '@' extract ] [ '[]' ]
/// engine     := css | xpath | json | regex | js
/// ```
///
/// `||` 与 `|>` 只在其后紧跟（可有空白）`<engine>:` 时才被视为运算符，
/// 因此 JS 代码、正则中的 `||` 不会被误切分。`|>` 的优先级高于 `||`。
library;

/// 表达式引擎前缀。
enum SelectorEngine { css, xpath, json, regex, js }

/// 提取方式（`@` 之后的部分）。
sealed class Extract {
  const Extract();
}

/// `@text`：文本内容，去首尾空白。
final class TextExtract extends Extract {
  const TextExtract();
  @override
  String toString() => '@text';
}

/// `@html`：内部 HTML。
final class HtmlExtract extends Extract {
  const HtmlExtract();
  @override
  String toString() => '@html';
}

/// `@outerHtml`：包含自身标签的 HTML。
final class OuterHtmlExtract extends Extract {
  const OuterHtmlExtract();
  @override
  String toString() => '@outerHtml';
}

/// `@<属性名>`。
final class AttrExtract extends Extract {
  const AttrExtract(this.name);
  final String name;
  @override
  String toString() => '@$name';
}

/// regex 的 `@<组号>`。
final class GroupExtract extends Extract {
  const GroupExtract(this.group);
  final int group;
  @override
  String toString() => '@$group';
}

/// 一个求值步骤，例如 `css:.item a@href[]`。
final class Step {
  const Step(this.engine, this.selector, {this.extract, this.multi = false});

  final SelectorEngine engine;
  final String selector;

  /// 显式指定的提取方式；为 `null` 时最终结果按默认方式（`@text` / 整个匹配）提取，
  /// 管道中间步骤则把原始节点传给下一步。
  final Extract? extract;

  /// 末尾是否有 `[]`（取全部匹配）。
  final bool multi;

  @override
  String toString() =>
      '${engine.name}:$selector${extract ?? ''}${multi ? '[]' : ''}';
}

/// `A |> B |> C`。
final class Pipeline {
  const Pipeline(this.steps);
  final List<Step> steps;
  @override
  String toString() => steps.join(' |> ');
}

/// 完整表达式：若干以 `||` 连接的管道。
final class Expression {
  const Expression(this.alternatives, this.source);

  final List<Pipeline> alternatives;

  /// 原始文本，用于日志。
  final String source;

  /// 表达式中出现的所有 `js:` 代码片段。
  Iterable<String> get jsSnippets => [
    for (final p in alternatives)
      for (final s in p.steps)
        if (s.engine == SelectorEngine.js) s.selector,
  ];

  @override
  String toString() => alternatives.join(' || ');

  /// 解析表达式；语法错误时抛出 [FormatException]。
  static Expression parse(String source) {
    final text = source.trim();
    if (text.isEmpty) throw const FormatException('表达式为空');
    final alternatives = [
      for (final alt in _split(text, '||'))
        Pipeline([for (final step in _split(alt, '|>')) _parseStep(step)]),
    ];
    return Expression(alternatives, source);
  }
}

final _enginePrefix = RegExp(r'^\s*(css|xpath|json|regex|js):');

/// 按运算符 [op] 切分，仅当运算符之后紧跟 `<engine>:` 时才切。
List<String> _split(String text, String op) {
  final parts = <String>[];
  var start = 0;
  var i = text.indexOf(op);
  while (i >= 0) {
    if (_enginePrefix.hasMatch(text.substring(i + op.length))) {
      parts.add(text.substring(start, i));
      start = i + op.length;
    }
    i = text.indexOf(op, i + op.length);
  }
  parts.add(text.substring(start));
  return parts;
}

// css 的 `@提取`：末尾的 `@标识符`。
final _cssExtract = RegExp(r'@([A-Za-z_][\w:.-]*)$');
// xpath 的 `@提取`：要求 `@` 前是名称、`]`、`)`、`*` 或引号，
// 以免把 `//a/@href`、`[@id]` 这类 XPath 自身的属性轴当成提取。
final _xpathExtract = RegExp(r'''(?<=[\w\])*'"])@([A-Za-z_][\w:.-]*)$''');
// regex 的 `@组号`。
final _groupExtract = RegExp(r'@(\d+)$');

Step _parseStep(String raw) {
  final text = raw.trim();
  final m = _enginePrefix.firstMatch(text);
  if (m == null) {
    throw FormatException('缺少引擎前缀（css/xpath/json/regex/js）', raw);
  }
  final engine = SelectorEngine.values.byName(m.group(1)!);
  var body = text.substring(m.end).trim();

  // js 片段原样保留：代码本身可能以 `[]` 结尾或包含 `@`。
  if (engine == SelectorEngine.js) {
    if (body.isEmpty) throw FormatException('js 代码为空', raw);
    return Step(engine, body);
  }

  var multi = false;
  if (body.endsWith('[]')) {
    multi = true;
    body = body.substring(0, body.length - 2).trimRight();
  }

  Extract? extract;
  switch (engine) {
    case SelectorEngine.css || SelectorEngine.xpath:
      final pattern = engine == SelectorEngine.css
          ? _cssExtract
          : _xpathExtract;
      final em = pattern.firstMatch(body);
      if (em != null) {
        extract = switch (em.group(1)!) {
          'text' => const TextExtract(),
          'html' => const HtmlExtract(),
          'outerHtml' => const OuterHtmlExtract(),
          final name => AttrExtract(name),
        };
        body = body.substring(0, em.start).trimRight();
      }
    case SelectorEngine.regex:
      final em = _groupExtract.firstMatch(body);
      if (em != null) {
        extract = GroupExtract(int.parse(em.group(1)!));
        body = body.substring(0, em.start);
      }
    case SelectorEngine.json:
      // JSONPath 自身用 `@` 表示过滤器中的当前节点，因此 json 不支持 `@提取`。
      break;
    case SelectorEngine.js:
      throw StateError('unreachable');
  }

  if (body.isEmpty) throw FormatException('选择器为空', raw);
  return Step(engine, body, extract: extract, multi: multi);
}
