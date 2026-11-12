import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:html/dom.dart' as dom;
import 'package:tsumugi/core/engine/expression/expression_engine.dart';
import 'package:tsumugi/core/engine/expression/js_evaluator.dart';
import 'package:tsumugi/core/engine/script/quickjs_script_runtime.dart';

SourceDocument fixture(String name) =>
    SourceDocument(File('test/fixtures/expression/$name').readAsStringSync());

void main() {
  late List<String> logs;
  late ExpressionEngine engine;
  late SourceDocument page;
  late SourceDocument data;

  setUp(() {
    logs = [];
    engine = ExpressionEngine(log: logs.add);
    page = fixture('page.html');
    data = fixture('data.json');
  });

  group('css', () {
    test('default extract is trimmed text', () async {
      expect(await engine.string('css:h1', page), 'Example Title');
      expect(await engine.string('css:h1@text', page), 'Example Title');
    });

    test('@html / @outerHtml / @attr', () async {
      expect(
        await engine.string('css:#intro@html', page),
        '<p>First <b>bold</b></p><p>Second</p>',
      );
      expect(
        await engine.string('css:#intro p@outerHtml', page),
        '<p>First <b>bold</b></p>',
      );
      expect(await engine.string('css:.item a@href', page), '/book/1');
      expect(await engine.string('css:.item a@missing', page), isNull);
    });

    test('single vs []', () async {
      expect(await engine.values('css:.item a@text', page), ['Book One']);
      expect(await engine.values('css:.item a@text[]', page), [
        'Book One',
        'Book Two',
        'Book Three',
      ]);
    });

    test('string input is parsed as HTML', () async {
      expect(await engine.string('css:b', '<p>x<b>y</b></p>'), 'y');
    });

    test('invalid selector logs and yields empty', () async {
      expect(await engine.string('css:a[[', page), isNull);
      expect(logs.single, contains('css:a[['));
    });

    test('JSON input is rejected', () async {
      expect(await engine.string('css:a', <String, Object?>{'a': 1}), isNull);
      expect(logs, hasLength(1));
    });
  });

  group('xpath', () {
    test('elements, attributes, text()', () async {
      expect(await engine.string('xpath://h1', page), 'Example Title');
      expect(
        await engine.strings("xpath://li[@class='item']/a/@href[]", page),
        ['/book/1', '/book/2', '/book/3'],
      );
      expect(
        await engine.string("xpath://div[@id='intro']/p[2]/text()", page),
        'Second',
      );
    });

    test('@ extracts on xpath elements', () async {
      expect(await engine.strings('xpath://li/a@data-id[]', page), [
        '1',
        '2',
        '3',
      ]);
      expect(
        await engine.string("xpath://div[@id='intro']@html", page),
        '<p>First <b>bold</b></p><p>Second</p>',
      );
      expect(await engine.string('xpath://b@outerHtml', page), '<b>bold</b>');
    });

    test('atomic results', () async {
      expect(await engine.string('xpath:count(//li)', page), '3');
      expect(
        await engine.string('xpath:normalize-space(//h1)', page),
        'Example Title',
      );
    });

    test('relative to a list node, then css on the result', () async {
      final items = await engine.nodes("xpath://li[@class='item']", page);
      expect(items, hasLength(3));
      expect(items.first, isA<dom.Element>());
      expect(await engine.string('xpath:./a/@href', items[1]), '/book/2');
      expect(await engine.string('css:a@data-id', items[2]), '3');
    });

    test('invalid xpath logs and yields empty', () async {
      expect(await engine.string('xpath://[', page), isNull);
      expect(logs, hasLength(1));
    });
  });

  group('json', () {
    test('scalars and lists', () async {
      expect(await engine.string(r'json:$.data.total', data), '3');
      expect(
        await engine.string(r'json:$.data.list[0].name', data),
        'Novel One',
      );
      expect(await engine.strings(r'json:$.data.list[*].id[]', data), [
        'n1',
        'n2',
        'n3',
      ]);
      // 没有 [] 时只取第一个。
      expect(await engine.values(r'json:$.data.list[*].id', data), ['n1']);
    });

    test('filters use @', () async {
      expect(
        await engine.strings(r'json:$.data.list[?@.score > 7.5].id[]', data),
        ['n1', 'n3'],
      );
    });

    test('nulls are skipped, objects are serialized', () async {
      expect(await engine.string(r'json:$.data.list[2].author', data), isNull);
      expect(
        await engine.string(r'json:$.data.list[0].tags', data),
        '["x","y"]',
      );
    });

    test('list nodes are JSON values usable by field expressions', () async {
      final items = await engine.nodes(r'json:$.data.list[*]', data);
      expect(items, hasLength(3));
      expect(await engine.string(r'json:$.name', items[0]), 'Novel One');
      expect(await engine.strings(r'json:$.tags[*][]', items[0]), ['x', 'y']);
    });

    test('string input is decoded', () async {
      expect(await engine.string(r'json:$.a', '{"a":"b"}'), 'b');
    });

    test('HTML document is not JSON', () async {
      expect(await engine.string(r'json:$.a', page), isNull);
      expect(logs, hasLength(1));
    });

    test('invalid JSONPath logs', () async {
      expect(await engine.string(r'json:$.[', data), isNull);
      expect(logs, hasLength(1));
    });
  });

  group('regex', () {
    test('group 0 by default, @n, []', () async {
      expect(
        await engine.string(r'regex:https://[^"]+\.m3u8', page),
        'https://video.example.com/v/1.m3u8',
      );
      expect(
        await engine.string(r'regex:"url":"(.+?)"@1', page),
        'https://video.example.com/v/1.m3u8',
      );
      expect(await engine.strings(r'regex:/book/(\d+)@1[]', page), [
        '1',
        '2',
        '3',
      ]);
    });

    test('missing group yields empty', () async {
      expect(await engine.string(r'regex:/book/(\d+)@5', page), isNull);
    });

    test('on an element uses its outer HTML', () async {
      final li = (await engine.nodes('css:li', page)).first;
      expect(await engine.string(r'regex:data-id="(\d)"@1', li), '1');
    });

    test('on JSON uses serialized text', () async {
      final items = await engine.nodes(r'json:$.data.list[*]', data);
      expect(await engine.string(r'regex:"id":"(\w+)"@1', items[1]), 'n2');
    });

    test('invalid regex logs', () async {
      expect(await engine.string('regex:(', page), isNull);
      expect(logs, hasLength(1));
    });
  });

  group('combinators', () {
    test('|| falls back when empty', () async {
      final items = await engine.nodes('css:.item', page);
      const cover = 'css:img@data-src || css:img@src';
      expect(await engine.string(cover, items[0]), '/c/1.jpg');
      expect(await engine.string(cover, items[1]), '/c/2.jpg');
      expect(await engine.string(cover, items[2]), isNull);
    });

    test('|| falls back after a failing step', () async {
      expect(await engine.string('css:a[[ || css:h1', page), 'Example Title');
      expect(logs, hasLength(1));
    });

    test('|> pipes a value into the next step', () async {
      expect(
        await engine.string(r'css:script@text |> regex:"alt":"(.+?)"@1', page),
        'https://video.example.com/v/1.mp4',
      );
      // 中间步骤无提取时传递节点。
      expect(await engine.string('css:#intro |> css:b', page), 'bold');
      // JSON 中嵌入的 HTML。
      expect(await engine.string(r'json:$.data.html |> css:.t', data), 'inner');
    });

    test('|> maps over multiple values', () async {
      expect(
        await engine.strings(r'css:.item a@href[] |> regex:(\d+)@1', page),
        ['1', '2', '3'],
      );
      // 只有第一步取单值时结果也是单值。
      expect(await engine.values(r'css:.item a@href |> regex:(\d+)@1', page), [
        '1',
      ]);
    });

    test('empty intermediate result stops the pipeline', () async {
      expect(await engine.string('css:.none |> css:a', page), isNull);
      expect(logs, isEmpty);
    });
  });

  group('helpers', () {
    test('truthy', () async {
      expect(await engine.truthy('css:.pagination .next', page), isTrue);
      expect(await engine.truthy('css:.pagination .prev', page), isFalse);
      expect(await engine.truthy(r'json:$.hasMore', data), isFalse);
      expect(await engine.truthy(r'json:$.code', data), isFalse);
      expect(await engine.truthy(r'json:$.data.total', data), isTrue);
      expect(await engine.truthy(null, page), isFalse);
    });

    test('nodes ignore [] and default extraction', () async {
      final items = await engine.nodes('css:.item', page);
      expect(items, hasLength(3));
      expect(items, everyElement(isA<dom.Element>()));
    });

    test('nodes keep elements without text', () async {
      expect(await engine.nodes('css:img', page), hasLength(2));
    });

    test('syntax error is logged once and cached', () async {
      expect(await engine.string('nope', page), isNull);
      expect(await engine.string('nope', page), isNull);
      expect(logs, hasLength(1));
    });
  });

  group('js', () {
    test('without an evaluator js steps are empty', () async {
      expect(await engine.string('js:"x" || css:h1', page), 'Example Title');
      expect(logs, hasLength(1));
    });

    group('with QuickJS', () {
      const snippets = [
        'result.trim().toUpperCase()',
        'result.map((s) => s + "!")',
        'result.length',
        'result.slice(0, 15)',
        'null',
        'JSON.parse(result).data.list.map((x) => x.id)',
        'result.nope()',
        'syntax error here (',
        '({ title: result })',
      ];
      late ScriptJsEvaluator js;

      setUp(() {
        js = ScriptJsEvaluator(QuickJsScriptRuntime.create, snippets);
        engine = ExpressionEngine(js: js, log: logs.add);
      });
      tearDown(() => js.dispose());

      test('post-processes a single value', () async {
        expect(
          await engine.string('css:h1 |> js:result.trim().toUpperCase()', page),
          'EXAMPLE TITLE',
        );
      });

      test('receives the whole list when multi', () async {
        expect(
          await engine.strings(
            'css:.item a@text[] |> js:result.map((s) => s + "!")',
            page,
          ),
          ['Book One!', 'Book Two!', 'Book Three!'],
        );
        expect(
          await engine.string('css:.item a@text[] |> js:result.length', page),
          '3',
        );
      });

      test('first step receives raw text', () async {
        expect(
          await engine.string('js:result.slice(0, 15)', page),
          '<!DOCTYPE html>',
        );
        expect(
          await engine.strings(
            'js:JSON.parse(result).data.list.map((x) => x.id)',
            data,
          ),
          ['n1', 'n2', 'n3'],
        );
      });

      test('object results are usable as nodes', () async {
        final nodes = await engine.nodes(
          'css:h1 |> js:({ title: result })',
          page,
        );
        expect(
          await engine.string(r'json:$.title', nodes.single),
          'Example Title',
        );
      });

      test('null result falls back', () async {
        expect(await engine.string('js:null || css:h1', page), 'Example Title');
      });

      test('runtime error logs and falls back', () async {
        expect(
          await engine.string('css:h1 |> js:result.nope() || css:a', page),
          'Book One',
        );
        expect(logs, hasLength(1));
      });

      test('a syntax error only breaks its own snippet', () async {
        expect(await engine.string('js:syntax error here (', page), isNull);
        expect(logs, hasLength(1));
        expect(
          await engine.string('css:h1 |> js:result.trim().toUpperCase()', page),
          'EXAMPLE TITLE',
        );
      });

      test('unregistered snippet fails', () async {
        expect(await engine.string('js:1 + 1', page), isNull);
        expect(logs.single, contains('未注册'));
      });
    });
  });
}
