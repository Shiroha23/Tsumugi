/// 本地 mock HTTP 服务器：用 `test/fixtures/mock_site/` 中的虚构页面模拟漫画 / 小说站点，
/// 供单元测试与手动调试规则使用。纯 Dart（只依赖 dart:io），不访问任何外部网络。
///
/// 服务器不区分 Host（任何虚构主机名都映射到同一套路由），请求的 Host 会记录在
/// [MockServer.requests] 中，并在 `/echo` 中返回。
///
/// 路由：
///
/// | 路径 | 说明 |
/// |---|---|
/// | `GET /comic/search?q=&page=` | 漫画搜索（第 1、2 页有结果，之后为空页） |
/// | `GET /comic/book/1` | 漫画详情（章节倒序） |
/// | `GET /comic/book/1/chapter/1` | 漫画章节（图片列表） |
/// | `GET /novel/search?q=` | 小说搜索 |
/// | `GET /novel/book/1` | 小说详情 |
/// | `GET /novel/book/1/chapter/1?p=1\|2` | 小说章节（章节内分页） |
/// | `GET /api/search?q=&page=` | JSON 搜索 API（分页） |
/// | `GET /api/book/b101` | JSON 详情 API |
/// | `GET /static/*`、`GET /covers/*`、`GET /pages/*` | 1×1 PNG |
/// | `* /echo` | 以 JSON 返回 method / host / path / query / headers / cookies / body |
/// | `POST /login`（form：user、pass=secret） | 成功时 `Set-Cookie: session=…` 并 303 到 `/members` |
/// | `GET /members` | 需要 `session` Cookie，否则 401 |
/// | `GET /cookie/set?name=&value=` | 设置任意 Cookie |
/// | `GET /challenge` | 403 + `cf-mitigated: challenge` 响应头 |
/// | `GET /challenge/page` | 503 + 含验证表单的页面 |
/// | `GET /slow?ms=` | 延迟 ms 毫秒后响应 |
/// | `GET /slow-body?ms=` | 先发送响应头，延迟后再发送响应体 |
/// | `GET /status/<code>` | 返回指定状态码 |
/// | `* /flaky?key=&fail=N&status=503` | 同一 key 的前 N 次返回 status（默认 503），之后 200 |
/// | `GET /drop` | 不发送响应直接断开连接 |
/// | `GET /large?bytes=N` | N 字节响应体 |
/// | `* /redirect?to=<url>&status=302` | 重定向到任意地址（相对或绝对） |
/// | `GET /redirect/chain?n=N` | 连续重定向 N 次后到 `/echo` |
/// | `GET /redirect/outside` | 302 到虚构的白名单外主机 `outside.example.net` |
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

class MockServer {
  MockServer._(this._server, this.fixturesDir);

  final HttpServer _server;

  /// `test/fixtures/mock_site` 目录。
  final Directory fixturesDir;

  /// 收到的全部请求（按到达顺序），便于断言重试次数、Host 等。
  final List<RecordedRequest> requests = [];

  final Map<String, int> _flakyCounters = {};

  int get port => _server.port;

  /// 例如 `http://127.0.0.1:54321`。
  Uri get origin => Uri(scheme: 'http', host: _server.address.host, port: port);

  /// [port] 为 0 时使用随机端口。[fixturesDir] 默认为当前目录下的 `test/fixtures/mock_site`。
  static Future<MockServer> start({
    int port = 0,
    InternetAddress? address,
    String? fixturesDir,
  }) async {
    final dir = Directory(fixturesDir ?? 'test/fixtures/mock_site');
    if (!dir.existsSync()) {
      throw StateError('fixtures directory not found: ${dir.absolute.path}');
    }
    final server = await HttpServer.bind(
      address ?? InternetAddress.loopbackIPv4,
      port,
    );
    final mock = MockServer._(server, dir);
    server.listen(mock._handle);
    return mock;
  }

  Future<void> close() => _server.close(force: true);

  /// 路径等于 [path] 的请求次数。
  int hits(String path) => requests.where((r) => r.path == path).length;

  Future<void> _handle(HttpRequest req) async {
    final body = await utf8.decoder.bind(req).join();
    requests.add(
      RecordedRequest(
        method: req.method,
        host: req.headers.host ?? '',
        path: req.uri.path,
        query: req.uri.queryParameters,
        headers: {
          for (final MapEntry(:key, :value) in _headerMap(req.headers).entries)
            key: value.join(', '),
        },
        body: body,
      ),
    );
    try {
      await _route(req, body);
    } catch (e, st) {
      stderr.writeln('mock_server: ${req.method} ${req.uri} failed: $e\n$st');
      try {
        req.response.statusCode = 500;
        await req.response.close();
      } catch (_) {}
    }
  }

  Future<void> _route(HttpRequest req, String body) async {
    final res = req.response;
    final path = req.uri.path;
    final q = req.uri.queryParameters;
    final segments = req.uri.pathSegments;

    switch (path) {
      case '/comic/search':
        final page = int.tryParse(q['page'] ?? '1') ?? 1;
        final file = switch (page) {
          1 => 'comic/search_1.html',
          2 => 'comic/search_2.html',
          _ => 'comic/search_empty.html',
        };
        return _html(res, file, {'keyword': q['q'] ?? '', 'page': '$page'});
      case '/comic/book/1':
        return _html(res, 'comic/detail_1.html');
      case '/comic/book/1/chapter/1':
        return _html(res, 'comic/chapter_1_1.html');
      case '/novel/search':
        return _html(res, 'novel/search.html', {'keyword': q['q'] ?? ''});
      case '/novel/book/1':
        return _html(res, 'novel/book_1.html');
      case '/novel/book/1/chapter/1':
        return _html(
          res,
          q['p'] == '2'
              ? 'novel/chapter_1_1_p2.html'
              : 'novel/chapter_1_1_p1.html',
        );
      case '/api/search':
        final page = int.tryParse(q['page'] ?? '1') ?? 1;
        if (page > 2) {
          return _json(res, {
            'code': 0,
            'data': {'page': page, 'hasMore': false, 'list': []},
          });
        }
        return _file(res, 'api/search_$page.json', ContentType.json);
      case '/api/book/b101':
        return _file(res, 'api/book_b101.json', ContentType.json);
      case '/echo':
        return _json(res, {
          'method': req.method,
          'host': req.headers.host,
          'path': path,
          'query': q,
          'headers': {
            for (final e in _headerMap(req.headers).entries)
              e.key: e.value.join(', '),
          },
          'cookies': {for (final c in req.cookies) c.name: c.value},
          'body': body,
        });
      case '/login':
        final form = Uri.splitQueryString(body);
        if (req.method == 'POST' && form['pass'] == 'secret') {
          final user = form['user'] ?? 'guest';
          res.cookies.add(
            Cookie('session', 'ok-${Uri.encodeComponent(user)}')
              ..path = '/'
              ..httpOnly = true,
          );
          res.statusCode = HttpStatus.seeOther;
          res.headers.set(HttpHeaders.locationHeader, '/members');
          return res.close();
        }
        res.statusCode = HttpStatus.unauthorized;
        return _json(res, {'error': 'bad credentials'});
      case '/members':
        final session = req.cookies
            .where((c) => c.name == 'session')
            .firstOrNull;
        if (session == null || !session.value.startsWith('ok-')) {
          res.statusCode = HttpStatus.unauthorized;
          return _json(res, {'error': 'login required'});
        }
        return _html(res, 'pages/members.html', {
          'user': Uri.decodeComponent(session.value.substring(3)),
        });
      case '/cookie/set':
        res.cookies.add(
          Cookie(q['name'] ?? 'c', q['value'] ?? '1')..path = '/',
        );
        return _json(res, {'ok': true});
      case '/challenge':
        res.statusCode = HttpStatus.forbidden;
        res.headers.set('cf-mitigated', 'challenge');
        res.headers.contentType = ContentType.html;
        res.write('<!doctype html><title>Access denied</title>');
        return res.close();
      case '/challenge/page':
        res.statusCode = HttpStatus.serviceUnavailable;
        return _html(res, 'pages/challenge.html');
      case '/slow':
        await Future<void>.delayed(_ms(q['ms'], 1000));
        return _json(res, {'slow': true});
      case '/slow-body':
        res.headers.contentType = ContentType.text;
        res.write('start;');
        await res.flush();
        await Future<void>.delayed(_ms(q['ms'], 1000));
        res.write('end');
        return res.close();
      case '/flaky':
        final key = q['key'] ?? '';
        final fail = int.tryParse(q['fail'] ?? '1') ?? 1;
        final count = _flakyCounters[key] = (_flakyCounters[key] ?? 0) + 1;
        if (count <= fail) {
          res.statusCode = int.tryParse(q['status'] ?? '') ?? 503;
          return _json(res, {'attempt': count, 'ok': false});
        }
        return _json(res, {'attempt': count, 'ok': true});
      case '/drop':
        final socket = await res.detachSocket(writeHeaders: false);
        socket.destroy();
        return;
      case '/large':
        final n = int.tryParse(q['bytes'] ?? '') ?? 1024;
        res.headers.contentType = ContentType.binary;
        res.contentLength = n;
        const chunk = 64 * 1024;
        for (var sent = 0; sent < n; sent += chunk) {
          res.add(List.filled(chunk < n - sent ? chunk : n - sent, 0x61));
        }
        return res.close();
      case '/redirect':
        res.statusCode = int.tryParse(q['status'] ?? '') ?? 302;
        res.headers.set(HttpHeaders.locationHeader, q['to'] ?? '/echo');
        return res.close();
      case '/redirect/chain':
        final n = int.tryParse(q['n'] ?? '') ?? 1;
        res.statusCode = HttpStatus.found;
        res.headers.set(
          HttpHeaders.locationHeader,
          n <= 1 ? '/echo' : '/redirect/chain?n=${n - 1}',
        );
        return res.close();
      case '/redirect/outside':
        res.statusCode = HttpStatus.found;
        res.headers.set(
          HttpHeaders.locationHeader,
          'http://outside.example.net/landing',
        );
        return res.close();
    }

    if (segments.length == 2 && segments[0] == 'status') {
      res.statusCode = int.tryParse(segments[1]) ?? 500;
      return _json(res, {'status': res.statusCode});
    }
    if (segments.isNotEmpty &&
        {'static', 'covers', 'pages'}.contains(segments.first) &&
        path.endsWith('.png')) {
      res.headers.contentType = ContentType('image', 'png');
      res.add(_png1x1);
      return res.close();
    }

    res.statusCode = HttpStatus.notFound;
    return _json(res, {'error': 'not found', 'path': path});
  }

  Future<void> _file(HttpResponse res, String name, ContentType type) async {
    res.headers.contentType = type;
    await res.addStream(File('${fixturesDir.path}/$name').openRead());
    return res.close();
  }

  Future<void> _html(
    HttpResponse res,
    String name, [
    Map<String, String> vars = const {},
  ]) async {
    var text = await File('${fixturesDir.path}/$name').readAsString();
    vars.forEach((k, v) => text = text.replaceAll('{{$k}}', _escape(v)));
    res.headers.contentType = ContentType.html;
    res.write(text);
    return res.close();
  }

  Future<void> _json(HttpResponse res, Object? value) {
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode(value));
    return res.close();
  }

  static Duration _ms(String? v, int fallback) =>
      Duration(milliseconds: int.tryParse(v ?? '') ?? fallback);

  static String _escape(String s) => const HtmlEscape().convert(s);

  static Map<String, List<String>> _headerMap(HttpHeaders headers) {
    final map = <String, List<String>>{};
    headers.forEach((name, values) => map[name] = values);
    return map;
  }

  /// 1×1 透明 PNG。
  static final _png1x1 = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
  );
}

class RecordedRequest {
  RecordedRequest({
    required this.method,
    required this.host,
    required this.path,
    required this.query,
    required this.headers,
    required this.body,
  });

  final String method;

  /// 不含端口的 Host。
  final String host;
  final String path;
  final Map<String, String> query;
  final Map<String, String> headers;
  final String body;

  @override
  String toString() => '$method $host$path';
}
