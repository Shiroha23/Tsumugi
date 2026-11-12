import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/engine/expression/expression.dart';

void main() {
  Step step(String src, [int alt = 0, int i = 0]) =>
      Expression.parse(src).alternatives[alt].steps[i];

  group('Expression.parse', () {
    test('engine prefixes', () {
      for (final e in SelectorEngine.values) {
        expect(step('${e.name}:x').engine, e);
      }
    });

    test('css extracts', () {
      expect(step('css:h1').extract, isNull);
      expect(step('css:h1@text').extract, isA<TextExtract>());
      expect(step('css:h1@html').extract, isA<HtmlExtract>());
      expect(step('css:h1@outerHtml').extract, isA<OuterHtmlExtract>());
      final attr = step('css:.item > a@data-id');
      expect(attr.selector, '.item > a');
      expect((attr.extract! as AttrExtract).name, 'data-id');
      // 属性选择器中的 @ 不是提取。
      expect(step('css:a[href\$="@x"]').extract, isNull);
    });

    test('multi suffix', () {
      final s = step('css:.tags a@text[]');
      expect(s.multi, isTrue);
      expect(s.selector, '.tags a');
      expect(s.extract, isA<TextExtract>());
      expect(step('css:.tags a[]').multi, isTrue);
      expect(step('css:.tags a').multi, isFalse);
    });

    test('xpath attribute axis is not an extract', () {
      final axis = step('xpath://a/@href');
      expect(axis.selector, '//a/@href');
      expect(axis.extract, isNull);
      expect(step("xpath://div[@class='t']/text()").extract, isNull);
      final ex = step('xpath://a@href[]');
      expect(ex.selector, '//a');
      expect((ex.extract! as AttrExtract).name, 'href');
      expect(ex.multi, isTrue);
      expect(step("xpath://div[@id='x']@html").extract, isA<HtmlExtract>());
    });

    test('json keeps @ inside filters', () {
      final s = step(r'json:$.list[?@.score > 8].name[]');
      expect(s.selector, r'$.list[?@.score > 8].name');
      expect(s.extract, isNull);
      expect(s.multi, isTrue);
    });

    test('regex group', () {
      final s = step('regex:src="(.+?)"@1[]');
      expect(s.selector, 'src="(.+?)"');
      expect((s.extract! as GroupExtract).group, 1);
      expect(s.multi, isTrue);
      expect(step(r'regex:\d+').extract, isNull);
    });

    test('js code is kept verbatim', () {
      final s = step('js:result.split("@")[0]');
      expect(s.selector, 'result.split("@")[0]');
      expect(s.extract, isNull);
      expect(step('js:[]').selector, '[]');
    });

    test('|| and |> split only before an engine prefix', () {
      final e = Expression.parse(
        'css:img@data-src || css:img@src |> regex:(\\d+)@1 || js:result',
      );
      expect(e.alternatives, hasLength(3));
      expect(e.alternatives[1].steps, hasLength(2));
      expect(e.alternatives[1].steps[1].engine, SelectorEngine.regex);

      final js = Expression.parse('js:result || "x" |> css:a');
      expect(js.alternatives, hasLength(1));
      expect(js.alternatives[0].steps, hasLength(2));
      expect(js.alternatives[0].steps[0].selector, 'result || "x"');

      final re = Expression.parse('regex:a||b@0');
      expect(re.alternatives, hasLength(1));
      expect(re.alternatives[0].steps[0].selector, 'a||b');
    });

    test('jsSnippets', () {
      expect(Expression.parse('js:a || css:x |> js:b').jsSnippets.toList(), [
        'a',
        'b',
      ]);
    });

    test('syntax errors', () {
      expect(() => Expression.parse(''), throwsFormatException);
      expect(() => Expression.parse('.title'), throwsFormatException);
      expect(() => Expression.parse('foo:.title'), throwsFormatException);
      expect(() => Expression.parse('css:'), throwsFormatException);
      expect(() => Expression.parse('css:@href'), throwsFormatException);
      expect(() => Expression.parse('js:'), throwsFormatException);
      expect(() => Expression.parse('css:a || css:'), throwsFormatException);
    });
  });
}
