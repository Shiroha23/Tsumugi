import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/network/host_policy.dart';
import 'package:tsumugi/core/network/session_persistence.dart';
import 'package:tsumugi/core/network/source_http_client.dart';
import 'package:tsumugi/core/network/source_session.dart';

import 'mock_support.dart';

void main() {
  late Directory dir;
  late List<String> logs;
  late SessionPersistence persistence;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('tsumugi_sessions_');
    logs = [];
    persistence = SessionPersistence.at(dir, log: logs.add);
  });
  tearDown(() => dir.delete(recursive: true));

  const a = 'com.example.comic';
  const b = 'com.example.other';
  final comic = Uri.parse('http://comic.example.com/');
  final comicHttps = Uri.parse('https://comic.example.com/');

  File fileOf(String id) =>
      File('${dir.path}/${SessionPersistence.fileNameFor(id)}');

  /// 模拟重启：用一个新的 [SessionPersistence] 实例读取同一目录。
  SourceSession restart(String id, {DateTime Function()? clock}) =>
      SourceSession.persistent(
        id,
        SessionPersistence.at(dir, log: logs.add),
        clock: clock,
      );

  Future<Map<String, String>> cookiesOn(SourceSession s, Uri uri) async => {
    for (final c in await s.cookieJar.loadForRequest(uri)) c.name: c.value,
  };

  group('文件名', () {
    test('sourceId 以 UTF-8 十六进制编码，可还原', () {
      expect(SessionPersistence.fileNameFor('a.b'), '612e62.json');
      for (final id in ['..', 'con', 'com.example.comic', '中文']) {
        final name = SessionPersistence.fileNameFor(id);
        expect(name, matches(RegExp(r'^[0-9a-f]+\.json$')));
        expect(SessionPersistence.sourceIdOf(name), id);
      }
      expect(SessionPersistence.sourceIdOf('readme.txt'), isNull);
      expect(SessionPersistence.sourceIdOf('6.json'), isNull);
      expect(SessionPersistence.sourceIdOf('ZZ.json'), isNull);
    });
  });

  group('重启后', () {
    test('Cookie（含会话 Cookie）与 UA 仍在', () async {
      final s = SourceSession.persistent(a, persistence);
      await s.cookieJar.saveFromResponse(comic, [
        Cookie('session', 'ok-1')
          ..path = '/'
          ..httpOnly = true,
        Cookie('pref', 'x')
          ..path = '/members'
          ..expires = DateTime.now().add(const Duration(days: 1)),
        Cookie('wide', 'w')
          ..domain = '.example.com'
          ..path = '/',
      ]);
      s.userAgent = 'TestUA/1.0';
      await persistence.idle(a);

      final r = restart(a);
      await r.ready;
      expect(r.userAgent, 'TestUA/1.0');
      expect(await cookiesOn(r, comic), {'session': 'ok-1', 'wide': 'w'});
      expect(
        await cookiesOn(r, Uri.parse('http://comic.example.com/members/1')),
        {'session': 'ok-1', 'pref': 'x', 'wide': 'w'},
      );
      // 带 Domain 的 Cookie 恢复后仍对子域名有效。
      expect(await cookiesOn(r, Uri.parse('http://img.example.com/')), {
        'wide': 'w',
      });
      final restored = await r.cookieJar.loadForRequest(comic);
      expect(restored.firstWhere((c) => c.name == 'session').httpOnly, isTrue);
    });

    test('WebView 同步（importCookies）写入的 Cookie 也持久化', () async {
      final s = SourceSession.persistent(a, persistence);
      final policy = HostPolicy(baseUrl: Uri.parse('http://comic.example.com'));
      expect(
        await s.importCookies(comic, const [
          WebCookie(name: 'cf_clearance', value: 'v', httpOnly: true),
        ], policy),
        1,
      );
      await persistence.idle(a);

      final r = restart(a);
      expect(await cookiesOn(r, comic), {'cf_clearance': 'v'});
    });

    test('Secure Cookie 仍不经 http 发送', () async {
      final s = SourceSession.persistent(a, persistence);
      await s.cookieJar.saveFromResponse(comicHttps, [
        Cookie('sec', '1')
          ..path = '/'
          ..secure = true,
        Cookie('plain', '2')..path = '/',
      ]);
      await persistence.idle(a);

      final r = restart(a);
      expect(await cookiesOn(r, comic), {'plain': '2'});
      expect(await cookiesOn(r, comicHttps), {'sec': '1', 'plain': '2'});
    });

    test('源与源互不可见，各自一个文件', () async {
      final sa = SourceSession.persistent(a, persistence);
      final sb = SourceSession.persistent(b, persistence);
      await sa.cookieJar.saveFromResponse(comic, [Cookie('only_a', '1')]);
      sb.userAgent = 'UA-B';
      await persistence.idle(a);
      await persistence.idle(b);

      expect(fileOf(a).existsSync(), isTrue);
      expect(fileOf(b).existsSync(), isTrue);
      expect(fileOf(b).readAsStringSync(), isNot(contains('only_a')));

      final ra = restart(a);
      final rb = restart(b);
      await rb.ready;
      expect(await cookiesOn(ra, comic), {'only_a': '1'});
      expect(await cookiesOn(rb, comic), isEmpty);
      expect(ra.userAgent, isNull);
      expect(rb.userAgent, 'UA-B');
    });
  });

  group('过期', () {
    test('Max-Age 换算为绝对时间；过期的不恢复，读取时清理并改写文件', () async {
      var now = DateTime.now();
      final s = SourceSession.persistent(a, persistence, clock: () => now);
      await s.cookieJar.saveFromResponse(comic, [
        Cookie('short', '1')
          ..path = '/'
          ..maxAge = 60,
        Cookie('long', '2')
          ..path = '/'
          ..expires = now.add(const Duration(days: 30)),
      ]);
      await persistence.idle(a);
      final saved = jsonDecode(fileOf(a).readAsStringSync()) as Map;
      final short = (saved['cookies'] as List).cast<Map>().firstWhere(
        (c) => c['name'] == 'short',
      );
      expect(short['expires'], isA<int>());

      // 2 分钟后：short 已过期。
      now = now.add(const Duration(minutes: 2));
      expect(await cookiesOn(s, comic), {'long': '2'});
      await persistence.idle(a);
      expect(fileOf(a).readAsStringSync(), isNot(contains('short')));

      final r = restart(a, clock: () => now);
      expect(await cookiesOn(r, comic), {'long': '2'});

      // 30 天后全部过期：加载时丢弃，并改写（这里是删除）文件。
      now = now.add(const Duration(days: 31));
      final p2 = SessionPersistence.at(dir);
      final r2 = SourceSession.persistent(a, p2, clock: () => now);
      await r2.ready;
      await p2.idle(a);
      expect(await cookiesOn(r2, comic), isEmpty);
      expect(fileOf(a).existsSync(), isFalse);
    });

    test('Max-Age 优先于 Expires（RFC 6265 §5.3）', () async {
      var now = DateTime.now();
      final s = SourceSession.persistent(a, persistence, clock: () => now);
      await s.cookieJar.saveFromResponse(comic, [
        Cookie('both', '1')
          ..path = '/'
          ..maxAge = 3600
          ..expires = now.add(const Duration(minutes: 10)),
      ]);
      now = now.add(const Duration(minutes: 30));
      expect(await cookiesOn(s, comic), {'both': '1'});
      await persistence.idle(a);
      final r = restart(a, clock: () => now);
      expect(await cookiesOn(r, comic), {'both': '1'});
    });

    test('超大 Max-Age / Expires 限制在 400 天，不影响读写', () async {
      final now = DateTime.now();
      final s = SourceSession.persistent(a, persistence, clock: () => now);
      await s.cookieJar.saveFromResponse(comic, [
        Cookie('huge', '1')
          ..path = '/'
          ..maxAge = 10000000000000,
        Cookie('far', '2')
          ..path = '/'
          ..expires = DateTime.utc(9999),
      ]);
      expect(await cookiesOn(s, comic), {'huge': '1', 'far': '2'});
      await persistence.idle(a);
      final saved = jsonDecode(fileOf(a).readAsStringSync()) as Map;
      final limit = now
          .add(PersistingCookieJar.maxCookieAge)
          .millisecondsSinceEpoch;
      for (final c in (saved['cookies'] as List).cast<Map>()) {
        expect(c['expires'], lessThanOrEqualTo(limit));
      }
      expect(await cookiesOn(restart(a), comic), {'huge': '1', 'far': '2'});
    });

    test('已过期的 Secure Cookie 不会发往 https', () async {
      var now = DateTime.now();
      final s = SourceSession(clock: () => now);
      await s.cookieJar.saveFromResponse(comicHttps, [
        Cookie('sec', '1')
          ..path = '/'
          ..secure = true
          ..expires = now.add(const Duration(seconds: 10)),
      ]);
      expect(await cookiesOn(s, comicHttps), {'sec': '1'});
      now = now.add(const Duration(minutes: 1));
      expect(await cookiesOn(s, comicHttps), isEmpty);
    });
  });

  group('并发', () {
    test('同一源多处同时写入不丢数据', () async {
      final s = SourceSession.persistent(a, persistence);
      await Future.wait([
        for (var i = 0; i < 50; i++)
          s.cookieJar.saveFromResponse(comic, [
            Cookie('c$i', '$i')..path = '/',
          ]),
        Future(() => s.userAgent = 'UA'),
      ]);
      await persistence.idle(a);

      final r = restart(a);
      final got = await cookiesOn(r, comic);
      expect(got, hasLength(50));
      expect(got['c49'], '49');
      expect(r.userAgent, 'UA');
      // 没有残留临时文件。
      expect(dir.listSync().map((e) => e.uri.pathSegments.last), [
        SessionPersistence.fileNameFor(a),
      ]);
    });

    test('加载完成前的写入排在加载之后，不被覆盖', () async {
      final s = SourceSession.persistent(a, persistence);
      await s.cookieJar.saveFromResponse(comic, [Cookie('old', '1')]);
      await persistence.idle(a);

      final p2 = SessionPersistence.at(dir);
      final r = SourceSession.persistent(a, p2);
      // 不等待 ready，立刻写入。
      r.userAgent = 'NEW';
      await r.cookieJar.saveFromResponse(comic, [Cookie('new', '2')]);
      await p2.idle(a);

      final r2 = restart(a);
      await r2.ready;
      expect(await cookiesOn(r2, comic), {'old': '1', 'new': '2'});
      expect(r2.userAgent, 'NEW');
    });
  });

  group('损坏', () {
    test('无法解析的文件被删除并记录日志，从空会话开始', () async {
      await fileOf(a).writeAsString('{ not json');
      final s = SourceSession.persistent(a, persistence);
      await s.ready;
      expect(await cookiesOn(s, comic), isEmpty);
      expect(fileOf(a).existsSync(), isFalse);
      expect(logs.single, contains('corrupt'));

      // 之后照常写入。
      await s.cookieJar.saveFromResponse(comic, [Cookie('k', 'v')]);
      await persistence.idle(a);
      expect(await cookiesOn(restart(a), comic), {'k': 'v'});
    });

    test('结构不对（版本、类型）同样按损坏处理', () async {
      for (final text in [
        '[]',
        '{"version": 99, "cookies": []}',
        '{"version": 1, "cookies": "x"}',
        '{"version": 1, "cookies": [], "userAgent": 3}',
      ]) {
        await fileOf(a).writeAsString(text);
        final s = restart(a);
        await s.ready;
        expect(fileOf(a).existsSync(), isFalse, reason: text);
      }
    });

    test('单个无效 Cookie 只跳过该条', () async {
      await fileOf(a).writeAsString(
        jsonEncode({
          'version': 1,
          'userAgent': 'UA',
          'cookies': [
            {'host': 'comic.example.com', 'name': 'ok', 'value': '1'},
            {'host': 'comic.example.com', 'name': 'bad name', 'value': '1'},
            {'host': 'comic.example.com', 'name': 'semi', 'value': 'a;b'},
            {'name': 'nohost', 'value': '1'},
            {'host': 'comic.example.com', 'name': 'x', 'expires': 'soon'},
            {
              'host': 'comic.example.com',
              'name': 'y',
              'expires': 8640000000000001,
            },
            42,
          ],
        }),
      );
      final p2 = SessionPersistence.at(dir);
      final s = SourceSession.persistent(a, p2);
      await s.ready;
      expect(await cookiesOn(s, comic), {'ok': '1'});
      expect(s.userAgent, 'UA');
      // 无效条目被从文件中清掉。
      await p2.idle(a);
      expect(fileOf(a).readAsStringSync(), isNot(contains('semi')));
    });
  });

  group('生命周期', () {
    test('clear 清空 Cookie、UA 与挑战地址并删除文件', () async {
      final s = SourceSession.persistent(a, persistence);
      await s.cookieJar.saveFromResponse(comic, [Cookie('k', 'v')]);
      s
        ..userAgent = 'UA'
        ..lastChallengeUrl = comic;
      await persistence.idle(a);
      expect(fileOf(a).existsSync(), isTrue);

      await s.clear();
      await persistence.idle(a);
      expect(await cookiesOn(s, comic), isEmpty);
      expect(s.userAgent, isNull);
      expect(s.lastChallengeUrl, isNull);
      expect(fileOf(a).existsSync(), isFalse);
      expect(await cookiesOn(restart(a), comic), isEmpty);
    });

    test('close 后不再写入；delete 删除文件', () async {
      final s = SourceSession.persistent(a, persistence);
      await s.cookieJar.saveFromResponse(comic, [Cookie('k', 'v')]);
      s.close();
      await persistence.delete(a);
      await s.cookieJar.saveFromResponse(comic, [Cookie('late', '1')]);
      s.userAgent = 'late';
      await persistence.idle(a);
      expect(fileOf(a).existsSync(), isFalse);
    });

    test('sweep 只删除不属于已安装源的会话文件与残留临时文件', () async {
      for (final id in [a, b]) {
        final s = SourceSession.persistent(id, persistence);
        await s.cookieJar.saveFromResponse(comic, [Cookie('k', id)]);
        await persistence.idle(id);
      }
      final tmp = File('${fileOf(a).path}.tmp')..writeAsStringSync('partial');
      final foreign = File('${dir.path}/notes.txt')..writeAsStringSync('keep');

      await persistence.sweep((id) => id == a);
      expect(fileOf(a).existsSync(), isTrue);
      expect(tmp.existsSync(), isFalse);
      expect(fileOf(b).existsSync(), isFalse);
      expect(foreign.existsSync(), isTrue);
    });

    test('sweep 删除前重新判断：列目录期间安装的源不会被误删', () async {
      final keep = <String>{};
      final s = SourceSession.persistent(b, persistence);
      await s.cookieJar.saveFromResponse(comic, [Cookie('k', 'v')]);
      await persistence.idle(b);

      final sweeping = persistence.sweep(keep.contains);
      keep.add(b); // 在清理真正执行前，b 被安装
      await sweeping;
      expect(fileOf(b).existsSync(), isTrue);
    });

    test('写入失败只记录日志，内存中的 Cookie 照常使用', () async {
      // 目标路径被一个目录占用：rename 失败。
      Directory(fileOf(a).path).createSync();
      final s = SourceSession.persistent(a, persistence);
      await s.cookieJar.saveFromResponse(comic, [Cookie('k', 'v')]);
      expect(await cookiesOn(s, comic), {'k': 'v'});
      expect(logs.where((l) => l.contains('save session failed')), isNotEmpty);
    });

    test('目录不可用时记录日志，请求照常进行', () async {
      final broken = SessionPersistence(
        () async => throw const FileSystemException('no dir'),
        log: logs.add,
      );
      final s = SourceSession.persistent(a, broken);
      await s.cookieJar.saveFromResponse(comic, [Cookie('k', 'v')]);
      expect(await cookiesOn(s, comic), {'k': 'v'});
      expect(logs, isNotEmpty);
    });
  });

  group('端到端（mock 服务器 /login → /members）', () {
    late MockServer server;
    setUp(() async => server = await MockServer.start());
    tearDown(() => server.close());

    test('登录后重建会话仍可访问 /members；其他源不行；清除后需重新登录', () async {
      final client = mockClient(
        server,
        session: SourceSession.persistent(a, persistence),
      );
      final login = await client.request(
        const NetRequest(
          '/login',
          method: 'POST',
          body: NetBody.form({'user': '测试', 'pass': 'secret'}),
        ),
      );
      expect(login.url.path, '/members');
      expect(login.status, 200);
      client.close();
      await persistence.idle(a);

      // 「重启」：新的持久化实例、新的会话与客户端。
      final restarted = SessionPersistence.at(dir);
      final session = SourceSession.persistent(a, restarted);
      final again = mockClient(server, session: session);
      addTearDown(again.close);
      final members = await again.request(const NetRequest('/members'));
      expect(members.status, 200);
      expect(members.text, contains('欢迎回来，测试'));

      final other = mockClient(
        server,
        sourceId: b,
        session: SourceSession.persistent(b, restarted),
      );
      addTearDown(other.close);
      expect((await other.request(const NetRequest('/members'))).status, 401);

      await session.clear();
      expect((await again.request(const NetRequest('/members'))).status, 401);
      await restarted.idle(a);
      final afterClear = mockClient(server, session: restart(a));
      addTearDown(afterClear.close);
      expect(
        (await afterClear.request(const NetRequest('/members'))).status,
        401,
      );
    });
  });
}
