import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/network/rate_limiter.dart';
import 'package:tsumugi/core/network/session_persistence.dart';
import 'package:tsumugi/core/storage/app_database.dart';
import 'package:tsumugi/sources/model/manifest.dart';
import 'package:tsumugi/sources/registry/source_registry.dart';
import 'package:tsumugi/sources/session/source_sessions.dart';

import '../../core/storage/test_database.dart';

String fixture(String name) =>
    File('test/fixtures/sources/$name').readAsStringSync();

String comicWith(Map<String, Object?> changes) => jsonEncode({
  ...jsonDecode(fixture('declarative_comic.json')) as Map,
  ...changes,
});

void main() {
  late Directory dir;
  late SessionPersistence persistence;
  late AppDatabase db;
  late SourceRegistry registry;
  late SourceSessions sessions;

  const id = 'com.example.comic';
  final site = Uri.parse('https://example.com/');

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('tsumugi_sessions_');
    persistence = SessionPersistence.at(dir);
    db = openTestDatabase();
    registry = SourceRegistry(db);
  });
  tearDown(() async {
    sessions.dispose();
    await db.close();
    await dir.delete(recursive: true);
  });

  File fileOf(String sourceId) =>
      File('${dir.path}/${SessionPersistence.fileNameFor(sourceId)}');

  /// 等待 registry 的 stream 推送并处理完。
  Future<void> settle() async {
    await pumpEventQueue();
    await persistence.idle(id);
  }

  Future<void> login(SourceSessions s) async {
    await s.of(id).cookieJar.saveFromResponse(site, [
      Cookie('session', 'ok')..path = '/',
    ]);
    await persistence.idle(id);
  }

  test('删除源时删除其 Cookie 文件；重新安装从空会话开始', () async {
    await registry.importText(fixture('declarative_comic.json'));
    sessions = SourceSessions.watching(registry, persistence: persistence);
    await settle();
    final old = sessions.of(id);
    await login(sessions);
    expect(fileOf(id).existsSync(), isTrue);

    await registry.remove(id);
    await settle();
    expect(old.isClosed, isTrue);
    expect(sessions.peek(id), isNull);
    expect(fileOf(id).existsSync(), isFalse);

    await registry.importText(fixture('declarative_comic.json'));
    await settle();
    final fresh = sessions.of(id);
    await fresh.ready;
    expect(await fresh.cookieJar.loadForRequest(site), isEmpty);
  });

  test('源升级（清单变化）时保留 Cookie', () async {
    await registry.importText(fixture('declarative_comic.json'));
    sessions = SourceSessions.watching(registry, persistence: persistence);
    await settle();
    await login(sessions);

    await registry.importText(comicWith({'version': '1.1.0'}));
    await settle();
    expect(fileOf(id).existsSync(), isTrue);
    final cookies = await sessions.of(id).cookieJar.loadForRequest(site);
    expect(cookies.map((c) => c.name), ['session']);
  });

  test('启动时清理已不属于任何已安装源的会话文件，已安装的保留', () async {
    await registry.importText(fixture('declarative_comic.json'));
    // 上次运行留下的：已安装源的会话与一个已被删除的源的会话。
    final previous = SourceSessions(persistence: persistence);
    await login(previous);
    await previous.of('com.example.gone').cookieJar.saveFromResponse(site, [
      Cookie('x', '1'),
    ]);
    await persistence.idle('com.example.gone');
    expect(fileOf('com.example.gone').existsSync(), isTrue);

    sessions = SourceSessions.watching(
      registry,
      persistence: SessionPersistence.at(dir),
    );
    await pumpEventQueue();
    await sessions.initialSweep;
    expect(fileOf('com.example.gone').existsSync(), isFalse);
    expect(fileOf(id).existsSync(), isTrue);

    final restored = sessions.of(id);
    expect((await restored.cookieJar.loadForRequest(site)).map((c) => c.name), [
      'session',
    ]);
  });

  test('clear 只清除该源', () async {
    sessions = SourceSessions(persistence: persistence);
    await login(sessions);
    await sessions.of('com.example.other').cookieJar.saveFromResponse(site, [
      Cookie('other', '1'),
    ]);
    await persistence.idle('com.example.other');

    await sessions.clear(id);
    await persistence.idle(id);
    expect(fileOf(id).existsSync(), isFalse);
    expect(await sessions.of(id).cookieJar.loadForRequest(site), isEmpty);
    expect(fileOf('com.example.other').existsSync(), isTrue);
    expect(
      (await sessions.of('com.example.other').cookieJar.loadForRequest(site))
          .map((c) => c.name),
      ['other'],
    );
  });

  group('限速令牌桶（source-spec §5）', () {
    SourceManifest manifestOf(String sourceId, {Map<String, Object?>? rate}) =>
        SourceManifest.fromJson({
          ...jsonDecode(fixture('declarative_comic.json')) as Map,
          'id': sourceId,
          'rateLimit': rate ?? {'requests': 1, 'perSeconds': 30},
        });

    test('同一源的 clientFor（源实例 / 图片 / 每次播放）共用令牌桶；不同源互不相通', () {
      sessions = SourceSessions();
      final a1 = sessions.clientFor(manifestOf('com.example.a'));
      final a2 = sessions.clientFor(manifestOf('com.example.a'));
      final b = sessions.clientFor(manifestOf('com.example.b'));
      addTearDown(() {
        a1.close();
        a2.close();
        b.close();
      });

      expect(identical(a1.session, a2.session), isTrue);
      final bucketA = a1.session.rateLimiter(a1.config.rateLimit);
      expect(bucketA, isNotNull);
      expect(
        identical(bucketA, a2.session.rateLimiter(a2.config.rateLimit)),
        isTrue,
      );
      expect(
        identical(
          a1.session.rateLimiter(null, lane: RateLimitLane.media),
          a2.session.rateLimiter(null, lane: RateLimitLane.media),
        ),
        isTrue,
      );

      expect(identical(a1.session, b.session), isFalse);
      expect(
        identical(bucketA, b.session.rateLimiter(b.config.rateLimit)),
        isFalse,
      );
      expect(
        identical(
          a1.session.rateLimiter(null, lane: RateLimitLane.media),
          b.session.rateLimiter(null, lane: RateLimitLane.media),
        ),
        isFalse,
      );
    });

    test('删除后重新安装的源从新会话（新令牌桶）开始', () {
      sessions = SourceSessions();
      final before = sessions.clientFor(manifestOf('com.example.a'));
      addTearDown(before.close);
      final bucket = before.session.rateLimiter(before.config.rateLimit);
      sessions.remove('com.example.a');
      final after = sessions.clientFor(manifestOf('com.example.a'));
      addTearDown(after.close);
      expect(
        identical(bucket, after.session.rateLimiter(after.config.rateLimit)),
        isFalse,
      );
    });
  });
}
