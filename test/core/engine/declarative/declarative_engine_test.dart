import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/engine/declarative/declarative_engine.dart';
import 'package:tsumugi/core/engine/declarative/fetcher.dart';
import 'package:tsumugi/core/engine/declarative/rules.dart';
import 'package:tsumugi/core/engine/declarative/template.dart';

class _StubFetcher implements Fetcher {
  _StubFetcher(this.body, {this.status = 200});
  final String body;
  final int status;
  final requests = <FetchRequest>[];
  @override
  Future<FetchResponse> fetch(FetchRequest request) async {
    requests.add(request);
    return FetchResponse(status: status, url: request.url, body: body);
  }
}

void main() {
  group('renderTemplate', () {
    test('replaces variables, tolerates spaces', () {
      expect(
        renderTemplate('/s?q={{keyword}}&p={{ page }}&x={{setting.a-b}}', {
          'keyword': 'k',
          'page': '2',
          'setting.a-b': 'v',
        }),
        '/s?q=k&p=2&x=v',
      );
    });

    test('missing variables become empty and are reported', () {
      final missing = <String>[];
      expect(
        renderTemplate('{{baseUrl}}/{{nope}}', {
          'baseUrl': 'https://example.com',
        }, onMissing: missing.add),
        'https://example.com/',
      );
      expect(missing, ['nope']);
    });

    test('resolveUrl', () {
      final base = Uri.parse('https://example.com/a/');
      expect(resolveUrl(base, '/x')?.toString(), 'https://example.com/x');
      expect(resolveUrl(base, 'y')?.toString(), 'https://example.com/a/y');
      expect(
        resolveUrl(base, '//cdn.example.com/z')?.toString(),
        'https://cdn.example.com/z',
      );
      expect(resolveUrl(base, '  '), isNull);
      expect(resolveUrl(base, 'http://[bad'), isNull);
    });
  });

  group('DeclarativeRules', () {
    test('defaults for detail / content requests', () {
      final r = DeclarativeRules.fromJson({
        'detail': {'fields': <String, Object?>{}},
        'content': {'images': 'css:img@src[]'},
      });
      expect(r.detail!.request.url, '{{id}}');
      expect(r.content!.request.url, '{{unitId}}');
      expect(r.content!.fields, {'images': 'css:img@src[]'});
      expect(r.search, isNull);
      expect(r.explore, isEmpty);
    });

    test('expressions lists every rule expression', () {
      final r = DeclarativeRules.fromJson({
        'search': {
          'request': {'url': '/s'},
          'list': 'css:li',
          'fields': {'id': 'css:a@href'},
          'hasMore': 'css:.next',
        },
        'detail': {
          'fields': {'title': 'css:h1'},
          'units': {
            'list': 'css:dd',
            'fields': {'id': 'js:result'},
          },
        },
        'content': {'text': 'css:p@text[]'},
      });
      expect(r.expressions.toList(), [
        'css:li',
        'css:a@href',
        'css:.next',
        'css:h1',
        'css:dd',
        'js:result',
        'css:p@text[]',
      ]);
    });

    for (final (name, json) in <(String, Map<String, dynamic>)>[
      ('search not an object', {'search': 'x'}),
      (
        'missing list',
        {
          'search': {
            'request': {'url': '/s'},
            'fields': <String, Object?>{},
          },
        },
      ),
      (
        'bad method',
        {
          'search': {
            'request': {'url': '/s', 'method': 'PUT'},
            'list': 'css:li',
          },
        },
      ),
      ('explore not an array', {'explore': <String, Object?>{}}),
      (
        'explore without name',
        {
          'explore': [
            {
              'request': {'url': '/s'},
              'list': 'css:li',
            },
          ],
        },
      ),
      (
        'reverse not bool',
        {
          'detail': {
            'units': {'list': 'css:li', 'reverse': 'yes'},
          },
        },
      ),
      (
        'field not a string',
        {
          'content': {'images': 1},
        },
      ),
      (
        'subtitles not a string or object',
        {
          'content': {'subtitles': 1},
        },
      ),
      (
        'subtitles empty shorthand',
        {
          'content': {'subtitles': ' '},
        },
      ),
      (
        'subtitles without list',
        {
          'content': {
            'subtitles': {
              'fields': {'url': 'css:a@href'},
            },
          },
        },
      ),
      (
        'subtitles without fields.url',
        {
          'content': {
            'subtitles': {
              'list': 'css:track',
              'fields': {'lang': 'xpath:@label'},
            },
          },
        },
      ),
      (
        'subtitles field not a string',
        {
          'content': {
            'subtitles': {
              'list': 'css:track',
              'fields': {'url': 'xpath:@src', 'lang': 1},
            },
          },
        },
      ),
      (
        'subtitles bad charset',
        {
          'content': {
            'subtitles': {
              'list': 'css:track',
              'fields': {'url': 'xpath:@src'},
              'charset': 'klingon',
            },
          },
        },
      ),
      (
        'subtitles charset not a string',
        {
          'content': {
            'subtitles': {
              'list': 'css:track',
              'fields': {'url': 'xpath:@src'},
              'charset': ['gbk'],
            },
          },
        },
      ),
    ]) {
      test('rejects $name', () {
        expect(() => DeclarativeRules.fromJson(json), throwsFormatException);
      });
    }
  });

  group('DeclarativeEngine', () {
    late List<String> logs;
    setUp(() => logs = []);

    DeclarativeEngine engine(
      Map<String, dynamic> rules,
      Fetcher fetcher, {
      String type = 'comic',
    }) => DeclarativeEngine(
      baseUrl: Uri.parse('https://example.com'),
      mediaType: type,
      rules: DeclarativeRules.fromJson(rules),
      fetcher: fetcher,
      log: logs.add,
    );

    test(
      'POST JSON body gets a JSON content type; rule headers apply',
      () async {
        final f = _StubFetcher('{"items":[]}');
        final e = engine({
          'search': {
            'request': {
              'url': '{{baseUrl}}/api',
              'method': 'post',
              'body': '{"q":"{{keyword}}"}',
              'headers': {'X-Page': '{{page}}'},
            },
            'list': r'json:$.items[*]',
          },
        }, f);
        final r = await e.search('a b', 3);
        expect(r, {'items': <Object?>[], 'hasMore': false});
        final req = f.requests.single;
        expect(req.url.toString(), 'https://example.com/api');
        expect(req.method, 'POST');
        expect(req.body, '{"q":"a%20b"}');
        expect(req.headers['X-Page'], '3');
        expect(req.headers['Content-Type'], startsWith('application/json'));
      },
    );

    test('non-2xx is E_HTTP with status', () async {
      final e = engine({
        'content': {'images': 'css:img@src[]'},
      }, _StubFetcher('', status: 503));
      await expectLater(
        e.content('/c/1'),
        throwsA(
          isA<DeclarativeException>()
              .having((x) => x.code, 'code', 'E_HTTP')
              .having((x) => x.status, 'status', 503),
        ),
      );
    });

    test('unknown fields and missing template variables are logged', () async {
      final e = engine({
        'content': {
          'request': {'url': '/c/{{unitId}}/{{oops}}'},
          'images': 'css:img@src[]',
          'text': 'css:p',
        },
      }, _StubFetcher('<img src="/a.jpg"><img>'));
      final r = await e.content('1');
      expect(r, {
        'images': [
          {'url': 'https://example.com/a.jpg'},
        ],
      });
      expect(logs, [contains('{{oops}}'), contains('`text`')]);
    });

    test('unknown media type is E_UNSUPPORTED', () async {
      final e = engine(
        {
          'content': {'x': 'css:a'},
        },
        _StubFetcher(''),
        type: 'podcast',
      );
      await expectLater(
        e.content('1'),
        throwsA(
          isA<DeclarativeException>().having(
            (x) => x.code,
            'code',
            'E_UNSUPPORTED',
          ),
        ),
      );
    });

    group('content.subtitles', () {
      Future<Map<String, Object?>> video(
        Map<String, dynamic> content,
        String body,
      ) => engine(
        {'content': content},
        _StubFetcher(body),
        type: 'video',
      ).content('1');

      test('没有 subtitles 键：结果中没有 subtitles（旧规则不受影响）', () async {
        final r = await video({
          'streams': 'css:a@href[]',
        }, '<a href="/v.mp4"></a>');
        expect(r, {
          'streams': [
            {'url': 'https://example.com/v.mp4', 'type': 'mp4'},
          ],
        });
        expect(logs, isEmpty);
      });

      test('subtitles 为 null：与省略相同', () async {
        final r = await video({
          'streams': 'css:a@href[]',
          'subtitles': null,
        }, '<a href="/v.mp4"></a>');
        expect(r.containsKey('subtitles'), isFalse);
        expect(logs, isEmpty);
      });

      test('简写：单个字幕', () async {
        final r = await video({
          'streams': 'css:a@href[]',
          'subtitles': 'css:video track@src[]',
        }, '<a href="/v.mp4"></a><video><track src="/s/1.vtt"></video>');
        expect(r['subtitles'], [
          {'url': 'https://example.com/s/1.vtt', 'format': 'vtt'},
        ]);
      });

      test('简写：多个字幕，按顺序；推断不出格式时省略', () async {
        final r = await video(
          {'subtitles': 'css:track@src[]'},
          '<track src="a.srt"><track src="/b.ASS"><track src="/c.sub">'
          '<track src="/d"><track src="/dir.srt/e">',
        );
        expect(r['subtitles'], [
          {'url': 'https://example.com/a.srt', 'format': 'srt'},
          {'url': 'https://example.com/b.ASS', 'format': 'ass'},
          {'url': 'https://example.com/c.sub'},
          {'url': 'https://example.com/d'},
          {'url': 'https://example.com/dir.srt/e'},
        ]);
      });

      test('简写：没有匹配时为空列表', () async {
        final r = await video({'subtitles': 'css:track@src[]'}, '<p></p>');
        expect(r['subtitles'], isEmpty);
      });

      test('JSON 列表：lang 为空时省略，format 不区分大小写', () async {
        final r = await video(
          {
            'subtitles': {
              'list': r'json:$.subs[*]',
              'fields': {
                'url': r'json:$.file',
                'lang': r'json:$.label',
                'format': r'json:$.type',
              },
            },
          },
          '{"subs":[{"file":"/z.ass","label":"简体中文"},'
          '{"file":"https://cdn.example.com/e.txt","label":"","type":"SRT"},'
          '{"label":"缺少 url"}]}',
        );
        expect(r['subtitles'], [
          {'url': 'https://example.com/z.ass', 'lang': '简体中文', 'format': 'ass'},
          {'url': 'https://cdn.example.com/e.txt', 'format': 'srt'},
        ]);
        expect(logs.single, contains('无效的地址'));
      });

      test('非法 format 丢弃该条目，不当作未给出', () async {
        final r = await video(
          {
            'subtitles': {
              'list': 'css:track',
              'fields': {'url': 'xpath:@src', 'format': 'xpath:@data-f'},
            },
          },
          '<track src="/a.srt" data-f="sub"><track src="/b.srt" data-f="ssa">',
        );
        expect(r['subtitles'], [
          {'url': 'https://example.com/b.srt', 'format': 'ass'},
        ]);
        expect(logs.single, contains('`sub`'));
      });

      test('fields 中的未知键警告并忽略', () async {
        final r = await video({
          'subtitles': {
            'list': 'css:track',
            'fields': {'url': 'xpath:@src', 'kind': 'xpath:@kind'},
          },
        }, '<track src="/a.vtt" kind="captions">');
        expect(r['subtitles'], [
          {'url': 'https://example.com/a.vtt', 'format': 'vtt'},
        ]);
        expect(logs.single, contains('`kind`'));
      });

      test('非 video 类型：警告并忽略', () async {
        final r = await engine(
          {
            'content': {
              'streams': 'css:a@href[]',
              'subtitles': 'css:track@src[]',
            },
          },
          _StubFetcher('<a href="/s.mp3"></a><track src="/a.vtt">'),
          type: 'music',
        ).content('1');
        expect(r.containsKey('subtitles'), isFalse);
        expect(logs.single, contains('`subtitles`'));
      });

      test('expressions 包含字幕规则中的表达式', () {
        final r = DeclarativeRules.fromJson({
          'content': {
            'streams': 'css:a',
            'subtitles': {
              'list': 'css:track',
              'fields': {'url': 'js:result', 'lang': 'xpath:@label'},
              'charset': 'GBK',
            },
          },
        });
        expect(r.expressions.toList(), [
          'css:a',
          'css:track',
          'js:result',
          'xpath:@label',
        ]);
        expect(r.content!.subtitles!.charset, 'GBK');
      });
    });

    test('lyrics without timestamps are plain text', () async {
      final e = engine(
        {
          'content': {'streams': 'css:a@href[]', 'lyrics': 'css:pre'},
        },
        _StubFetcher('<a href="/s.mp3"></a><pre>just words</pre>'),
        type: 'music',
      );
      expect(await e.content('1'), {
        'streams': [
          {'url': 'https://example.com/s.mp3'},
        ],
        'lyrics': {'format': 'text', 'content': 'just words'},
      });
    });

    test('units without id are skipped; missing title is empty', () async {
      final e = engine({
        'detail': {
          'fields': <String, Object?>{},
          'units': {
            'list': 'css:li',
            'fields': {'id': 'css:a@href', 'title': 'css:a'},
          },
        },
      }, _StubFetcher('<li><a href="/1"></a></li><li>none</li>'));
      final d = await e.detail('/b');
      expect(d['title'], '');
      expect(d['units'], [
        {'id': '/1', 'title': '', 'index': 0},
      ]);
      expect(logs, hasLength(2)); // title 为空 + 跳过 unit
    });
  });
}
