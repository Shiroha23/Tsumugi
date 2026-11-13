import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/network/session_persistence.dart';
import 'package:tsumugi/core/storage/app_database.dart';
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
}
