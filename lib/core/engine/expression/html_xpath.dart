import 'package:html/dom.dart' as html;
import 'package:xml/xml.dart' as xml;
import 'package:xml/xpath.dart';

/// 在 `package:html` 的 DOM 上执行 XPath。
///
/// `package:xml` 的 XPath 实现只作用于它自己的 DOM，因此为每棵 HTML 树建一个只读的
/// XML 镜像（元素名、属性、文本、注释），求值后再把结果节点映射回 HTML 节点，
/// 使 `@html` / `@outerHtml` 以及后续的 css 步骤都能继续使用原节点。
///
/// 镜像不带命名空间，因此 `//div` 可以直接匹配 HTML 元素。镜像按树根缓存。
class HtmlXPath {
  final _mirrors = Expando<_Mirror>('xpath-mirror');

  /// 以 [context] 为上下文节点求值。返回值中的元素为 [html.Node]，
  /// 属性、文本节点与原子值为 [String]。
  List<Object> evaluate(html.Node context, String expression) {
    final root = _rootOf(context);
    final mirror = _mirrors[root] ??= _Mirror(root);
    final start = mirror.toXml[context];
    if (start == null) return const [];
    final result = <Object>[];
    for (final item in start.xpathEvaluate(expression)) {
      if (item is XPathNode) {
        final node = item.node;
        final back = mirror.toHtml[node];
        if (back != null && node is! xml.XmlText) {
          result.add(back);
        } else {
          result.add(item.stringValue);
        }
      } else {
        result.add(item.stringValue);
      }
    }
    return result;
  }

  static html.Node _rootOf(html.Node node) {
    var n = node;
    while (n.parentNode != null) {
      n = n.parentNode!;
    }
    return n;
  }
}

class _Mirror {
  _Mirror(html.Node root) {
    final doc = xml.XmlDocument();
    if (root is html.Document) {
      _link(root, doc);
      for (final child in root.nodes) {
        // XmlDocument 只允许元素与注释等作为直接子节点。
        if (child is html.Element || child is html.Comment) {
          final x = _convert(child);
          if (x != null) doc.children.add(x);
        }
      }
    } else {
      // 片段或游离的元素：放进一个合成的根元素。
      final wrapper = xml.XmlElement(xml.XmlName.qualified('fragment'));
      _link(root, wrapper);
      final x = root is html.Element ? _convert(root) : null;
      if (x != null) {
        wrapper.children.add(x);
      } else {
        for (final child in root.nodes) {
          final c = _convert(child);
          if (c != null) wrapper.children.add(c);
        }
      }
      doc.children.add(wrapper);
    }
  }

  final toXml = Map<html.Node, xml.XmlNode>.identity();
  final toHtml = Map<xml.XmlNode, html.Node>.identity();

  void _link(html.Node h, xml.XmlNode x) {
    toXml[h] = x;
    toHtml[x] = h;
  }

  xml.XmlNode? _convert(html.Node node) {
    switch (node) {
      case html.Element():
        final element = xml.XmlElement(
          xml.XmlName.qualified(node.localName ?? 'unknown'),
          [
            for (final e in node.attributes.entries)
              xml.XmlAttribute(
                xml.XmlName.qualified(e.key.toString()),
                e.value,
              ),
          ],
          const [],
          false,
        );
        _link(node, element);
        for (final child in node.nodes) {
          final x = _convert(child);
          if (x != null) element.children.add(x);
        }
        return element;
      case html.Text():
        final text = xml.XmlText(node.data);
        _link(node, text);
        return text;
      case html.Comment():
        return xml.XmlComment(node.data ?? '');
      default:
        return null;
    }
  }
}
