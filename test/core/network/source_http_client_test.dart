import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/network/dio_source_http_client.dart';
import 'package:tsumugi/core/network/network_exception.dart';
import 'package:tsumugi/core/network/source_http_client.dart';

import 'mock_support.dart';

Matcher throwsNet(NetworkErrorKind kind, {int? status, String? host}) =>
    throwsA(
      isA<NetworkException>()
          .having((e) => e.kind, 'kind', kind)
          .having(
            (e) => status == null || e.status == status,
            'status == $status',
            isTrue,
          )
          .having(
            (e) => host == null || e.uri?.host == host,
            'uri.host == $host',
            isTrue,
          ),
    );

void main() {
  late MockServer server;
  late DioSourceHttpClient client;

  setUpAll(() async => server = await MockServer.start());
  tearDownAll(() => server.close());

  setUp(
    () => client = mockClient(
      server,
      headers: {'Referer': 'http://comic.example.com/'},
    ),
  );
  tearDown(() => client.close());

  int hitsWhere(bool Function(RecordedRequest r) test) =>
      server.requests.where(test).length;

  group('基本请求', () {
    test('相对 URL 基于 baseUrl，带上默认 headers', () async {
      final res = await client.request(const NetRequest('/comic/book/1'));
      expect(res.status, 200);
      expect(res.ok, isTrue);
      expect(res.url.toString(), 'http://comic.example.com/comic/book/1');
      expect(res.text, contains('星之栖处'));
      expect(res.header('Content-Type'), contains('text/html'));
      final last = server.requests.last;
      expect(last.host, 'comic.example.com');
      expect(last.headers['referer'], 'http://comic.example.com/');
    });

    test('请求 headers 覆盖同名默认 header（不区分大小写）', () async {
      final echo = await client.getJson(
        '/echo',
        headers: {'REFERER': 'http://comic.example.com/x'},
      ) as Map;
      expect(echo['headers']['referer'], 'http://comic.example.com/x');
    });

    test('getText / getJson 便捷方法', () async {
      final html = await client.getText('/comic/search?q=星&page=2');
      expect(html, contains('灯塔与猫'));
      expect(html, contains('“星”的搜索结果'));
      final json = await client.getJson('/api/search?page=1') as Map;
      expect(json['data']['hasMore'], isTrue);
      expect((json['data']['list'] as List).length, 2);
    });

    test('JSON / form / text / bytes 请求体', () async {
      Future<Map> echo(NetBody body) async =>
          (await client.request(
                NetRequest('/echo', method: 'post', body: body),
              )).json()
              as Map;

      final j = await echo(const NetBody.json({'a': 1, 'b': '中'}));
      expect(j['method'], 'POST');
      expect(j['headers']['content-type'], startsWith('application/json'));
      expect(j['body'], '{"a":1,"b":"中"}');

      final f = await echo(const NetBody.form({'q': 'a b&c', 'n': '中'}));
      expect(f['headers']['content-type'], 'application/x-www-form-urlencoded');
      expect(Uri.splitQueryString(f['body'] as String), {
        'q': 'a b&c',
        'n': '中',
      });

      final t = await echo(const NetBody.text('hello'));
      expect(t['headers']['content-type'], startsWith('text/plain'));
      expect(t['body'], 'hello');

      final b = await echo(const NetBody.bytes([104, 105]));
      expect(b['headers']['content-type'], 'application/octet-stream');
      expect(b['body'], 'hi');
    });

    test('HEAD 请求', () async {
      final res = await client.request(
        const NetRequest('/echo', method: 'HEAD'),
      );
      expect(res.status, 200);
      expect(res.bytes, isEmpty);
    });
  });

  group('白名单', () {
    test('拒绝白名单外的主机，且不发出请求', () async {
      final before = server.requests.length;
      await expectLater(
        client.request(const NetRequest('http://evil.example.net/echo')),
        throwsNet(NetworkErrorKind.hostNotAllowed, host: 'evil.example.net'),
      );
      await expectLater(
        client.request(const NetRequest('file:///etc/passwd')),
        throwsNet(NetworkErrorKind.hostNotAllowed),
      );
      expect(server.requests.length, before);
    });

    test('允许 allowedHosts 中的主机', () async {
      final res = await client.request(
        const NetRequest('http://img.example.com/covers/1.png'),
      );
      expect(res.status, 200);
      expect(res.header('content-type'), 'image/png');
      expect(server.requests.last.host, 'img.example.com');
    });

    test('重定向到白名单外主机时拒绝', () async {
      await expectLater(
        client.request(const NetRequest('/redirect/outside')),
        throwsNet(NetworkErrorKind.hostNotAllowed, host: 'outside.example.net'),
      );
      expect(hitsWhere((r) => r.host == 'outside.example.net'), 0);
    });

    test('重定向到非 http(s) 地址时拒绝', () async {
      await expectLater(
        client.request(
          NetRequest(
            '/redirect?to=${Uri.encodeQueryComponent('file:///etc/passwd')}',
          ),
        ),
        throwsNet(NetworkErrorKind.hostNotAllowed),
      );
    });

    test('重定向到白名单内的其他主机时跟随', () async {
      final to = Uri.encodeQueryComponent('http://img.example.com/echo');
      final res = await client.request(NetRequest('/redirect?to=$to'));
      expect(res.status, 200);
      expect(res.url.host, 'img.example.com');
      expect((res.json() as Map)['host'], 'img.example.com');
    });

    test('跨主机重定向不携带调用方设置的 Authorization / Cookie', () async {
      final to = Uri.encodeQueryComponent('http://img.example.com/echo');
      final res = await client.request(
        NetRequest(
          '/redirect?to=$to',
          headers: {'Authorization': 'Bearer t', 'Cookie': 'manual=1'},
        ),
      );
      final headers = (res.json() as Map)['headers'] as Map;
      expect(headers.containsKey('authorization'), isFalse);
      expect(headers.containsKey('cookie'), isFalse);
    });

    test('followRedirects=false 时返回 3xx 本身（即使目标在白名单外）', () async {
      final res = await client.request(
        const NetRequest(
          '/redirect/outside',
          followRedirects: false,
          throwOnHttpError: true,
        ),
      );
      expect(res.status, 302);
      expect(res.header('location'), 'http://outside.example.net/landing');
    });

    test('超过重定向上限', () async {
      final res = await client.request(const NetRequest('/redirect/chain?n=5'));
      expect(res.status, 200);
      await expectLater(
        client.request(const NetRequest('/redirect/chain?n=6')),
        throwsNet(NetworkErrorKind.tooManyRedirects),
      );
    });

    test('303 改为 GET 并丢弃请求体；307 保留 method 与请求体', () async {
      final r303 = await client.request(
        const NetRequest(
          '/redirect?status=303&to=/echo',
          method: 'POST',
          body: NetBody.text('payload'),
        ),
      );
      expect((r303.json() as Map)['method'], 'GET');
      expect((r303.json() as Map)['body'], '');

      final r307 = await client.request(
        const NetRequest(
          '/redirect?status=307&to=/echo',
          method: 'POST',
          body: NetBody.text('payload'),
        ),
      );
      expect((r307.json() as Map)['method'], 'POST');
      expect((r307.json() as Map)['body'], 'payload');
    });
  });

  group('Cookie 隔离', () {
    test('登录 Cookie 只属于登录的那个源', () async {
      final other = mockClient(server, sourceId: 'com.example.other');
      addTearDown(other.close);

      final login = await client.request(
        const NetRequest(
          '/login',
          method: 'POST',
          body: NetBody.form({'user': '测试', 'pass': 'secret'}),
        ),
      );
      // 303 → /members，重定向那一跳已带上刚写入的 Cookie
      expect(login.status, 200);
      expect(login.url.path, '/members');
      expect(login.text, contains('欢迎回来，测试'));

      expect((await client.request(const NetRequest('/members'))).status, 200);
      expect((await other.request(const NetRequest('/members'))).status, 401);

      expect(await client.getCookies('/'), contains('session'));
      expect(await other.getCookies('/'), isEmpty);
    });

    test('Cookie 按主机隔离，不发往白名单内的其他主机', () async {
      await client.request(const NetRequest('/cookie/set?name=k&value=v'));
      final same = await client.getJson('/echo') as Map;
      expect(same['cookies'], {'k': 'v'});
      final img = await client.getJson('http://img.example.com/echo') as Map;
      expect(img['cookies'], isEmpty);
    });

    test('setCookie / getCookies / clearCookies', () async {
      await client.setCookie('http://comic.example.com/', 'cf', 'passed');
      expect(await client.getCookies('http://comic.example.com/a/b'), {
        'cf': 'passed',
      });
      final echo = await client.getJson('/echo') as Map;
      expect(echo['cookies'], {'cf': 'passed'});

      await client.clearCookies();
      expect(await client.getCookies('/'), isEmpty);
    });

    test('Cookie API 也受白名单限制', () async {
      await expectLater(
        client.getCookies('http://evil.example.net/'),
        throwsNet(NetworkErrorKind.hostNotAllowed),
      );
      await expectLater(
        client.setCookie('http://evil.example.net/', 'a', 'b'),
        throwsNet(NetworkErrorKind.hostNotAllowed),
      );
      await expectLater(
        client.setCookie('/', 'bad name', 'b'),
        throwsNet(NetworkErrorKind.invalidRequest),
      );
    });
  });

  group('限速', () {
    test('令牌桶：突发 requests 个，之后按速率放行', () async {
      final limited = mockClient(
        server,
        rateLimit: const RateLimitConfig(
          requests: 2,
          per: Duration(seconds: 1),
        ),
      );
      addTearDown(limited.close);

      final sw = Stopwatch()..start();
      final done = <int>[];
      await Future.wait([
        for (var i = 0; i < 5; i++)
          limited
              .request(const NetRequest('/echo'))
              .then((_) => done.add(sw.elapsedMilliseconds)),
      ]);
      done.sort();
      // 前 2 个立即发出，其余 3 个每 500ms 一个 → 总计约 1.5s
      expect(done[1], lessThan(400));
      expect(done[2], greaterThanOrEqualTo(400));
      expect(done[4], greaterThanOrEqualTo(1400));
    });

    test('不同源的限速互不影响', () async {
      final slowSource = mockClient(
        server,
        rateLimit: const RateLimitConfig(
          requests: 1,
          per: Duration(seconds: 2),
        ),
      );
      addTearDown(slowSource.close);
      await slowSource.request(const NetRequest('/echo'));
      final pending = slowSource.request(const NetRequest('/echo'));

      final sw = Stopwatch()..start();
      await client.request(const NetRequest('/echo'));
      expect(sw.elapsedMilliseconds, lessThan(1000));
      await pending;
    });

    test('在限速队列中等待时取消，立即失败且不发出请求', () async {
      final limited = mockClient(
        server,
        rateLimit: const RateLimitConfig(
          requests: 1,
          per: Duration(seconds: 30),
        ),
      );
      addTearDown(limited.close);
      await limited.request(const NetRequest('/echo?q=first'));

      final before = server.requests.length;
      final cancel = NetCancellation();
      final queued = limited.request(
        NetRequest('/echo?q=queued', cancellation: cancel),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final sw = Stopwatch()..start();
      cancel.cancel();
      await expectLater(queued, throwsNet(NetworkErrorKind.cancelled));
      expect(sw.elapsedMilliseconds, lessThan(1000));
      expect(server.requests.length, before);
    });
  });

  group('重试', () {
    int flakyHits(String key) =>
        hitsWhere((r) => r.path == '/flaky' && r.query['key'] == key);

    test('幂等请求遇到 5xx 时重试', () async {
      final res = await client.request(
        const NetRequest('/flaky?key=g1&fail=2'),
      );
      expect(res.status, 200);
      expect((res.json() as Map)['attempt'], 3);
      expect(flakyHits('g1'), 3);
    });

    test('重试次数有限', () async {
      final res = await client.request(
        const NetRequest('/flaky?key=g2&fail=10'),
      );
      expect(res.status, 503);
      expect(flakyHits('g2'), 3); // 1 + maxRetries(2)
      await expectLater(
        client.request(
          const NetRequest('/flaky?key=g3&fail=10', throwOnHttpError: true),
        ),
        throwsNet(NetworkErrorKind.http, status: 503),
      );
    });

    test('非幂等请求（POST）不重试', () async {
      final res = await client.request(
        const NetRequest('/flaky?key=p1&fail=1', method: 'POST'),
      );
      expect(res.status, 503);
      expect(flakyHits('p1'), 1);
    });

    test('4xx 不重试', () async {
      final res = await client.request(
        const NetRequest('/flaky?key=g4&fail=1&status=404'),
      );
      expect(res.status, 404);
      expect(flakyHits('g4'), 1);
    });

    test('连接错误重试后仍失败 → connection', () async {
      final before = server.hits('/drop');
      await expectLater(
        client.request(const NetRequest('/drop')),
        throwsNet(NetworkErrorKind.connection),
      );
      expect(server.hits('/drop') - before, 3);
    });
  });

  group('超时与取消', () {
    test('等待响应超时，且不重试', () async {
      final fast = mockClient(
        server,
        timeout: const Duration(milliseconds: 300),
      );
      addTearDown(fast.close);
      final before = server.hits('/slow');
      final sw = Stopwatch()..start();
      await expectLater(
        fast.request(const NetRequest('/slow?ms=3000')),
        throwsNet(NetworkErrorKind.timeout),
      );
      expect(sw.elapsedMilliseconds, lessThan(2000));
      expect(server.hits('/slow') - before, 1);
    });

    test('读取响应体超时', () async {
      await expectLater(
        client.request(
          const NetRequest(
            '/slow-body?ms=3000',
            timeout: Duration(milliseconds: 300),
          ),
        ),
        throwsNet(NetworkErrorKind.timeout),
      );
    });

    test('请求级 timeout 可放宽', () async {
      final fast = mockClient(
        server,
        timeout: const Duration(milliseconds: 100),
      );
      addTearDown(fast.close);
      final res = await fast.request(
        const NetRequest('/slow?ms=300', timeout: Duration(seconds: 3)),
      );
      expect(res.status, 200);
    });

    test('取消进行中的请求', () async {
      final cancel = NetCancellation();
      final future = client.request(
        NetRequest('/slow?ms=3000', cancellation: cancel),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      cancel.cancel();
      await expectLater(future, throwsNet(NetworkErrorKind.cancelled));
      // 已取消的信号让后续请求直接失败
      await expectLater(
        client.request(NetRequest('/echo', cancellation: cancel)),
        throwsNet(NetworkErrorKind.cancelled),
      );
    });
  });

  group('错误分类', () {
    test('默认返回非 2xx 响应；throwOnHttpError 时抛出 http', () async {
      final res = await client.request(const NetRequest('/status/404'));
      expect(res.status, 404);
      expect(res.ok, isFalse);
      await expectLater(
        client.request(const NetRequest('/status/404', throwOnHttpError: true)),
        throwsNet(NetworkErrorKind.http, status: 404),
      );
      await expectLater(
        client.getText('/status/401'),
        throwsNet(NetworkErrorKind.http, status: 401),
      );
    });

    test('JSON 解析失败 → decode', () async {
      await expectLater(
        client.getJson('/comic/book/1'),
        throwsNet(NetworkErrorKind.decode),
      );
    });

    test('响应体超过上限 → responseTooLarge', () async {
      final small = mockClient(server, maxResponseBytes: 1000);
      addTearDown(small.close);
      expect(
        (await small.request(const NetRequest('/large?bytes=1000')))
            .bytes
            .length,
        1000,
      );
      await expectLater(
        small.request(const NetRequest('/large?bytes=200000')),
        throwsNet(NetworkErrorKind.responseTooLarge),
      );
    });

    test('HEAD 声明的大小超过上限时不报错（没有响应体）', () async {
      final small = mockClient(server, maxResponseBytes: 1000);
      addTearDown(small.close);
      final res = await small.request(
        const NetRequest('/large?bytes=200000', method: 'HEAD'),
      );
      expect(res.status, 200);
      expect(res.header('content-length'), '200000');
      expect(res.bytes, isEmpty);
    });

    test('不支持的 method → invalidRequest', () async {
      await expectLater(
        client.request(const NetRequest('/echo', method: 'TRACE')),
        throwsNet(NetworkErrorKind.invalidRequest),
      );
    });

    test('无法连接 → connection', () async {
      final dead = await MockServer.start();
      final c = mockClient(dead, maxRetries: 0);
      addTearDown(c.close);
      await dead.close();
      await expectLater(
        c.request(const NetRequest('/echo')),
        throwsNet(NetworkErrorKind.connection),
      );
    });
  });

  group('人机验证检测', () {
    test('403 + 特征响应头 → challenge（附带页面地址）', () async {
      await expectLater(
        client.request(const NetRequest('/challenge')),
        throwsNet(
          NetworkErrorKind.challenge,
          status: 403,
          host: 'comic.example.com',
        ),
      );
    });

    test('503 + 验证页面特征 → challenge，且不重试', () async {
      final before = server.hits('/challenge/page');
      await expectLater(
        client.request(const NetRequest('/challenge/page')),
        throwsNet(NetworkErrorKind.challenge, status: 503),
      );
      expect(server.hits('/challenge/page') - before, 1);
    });

    test('普通 403 / 503 不是 challenge', () async {
      expect(
        (await client.request(const NetRequest('/status/403'))).status,
        403,
      );
      // 普通 503 会按默认策略重试，最终仍返回 503 而不是 challenge
      expect(
        (await client.request(const NetRequest('/status/503'))).status,
        503,
      );
    });
  });
}
