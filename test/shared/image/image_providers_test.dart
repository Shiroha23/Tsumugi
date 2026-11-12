import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/storage/app_database.dart';
import 'package:tsumugi/shared/image/image_providers.dart';
import 'package:tsumugi/sources/registry/providers.dart';
import 'package:tsumugi/sources/source.dart';

import '../../core/storage/test_database.dart';

String manifest({String version = '1.0.0', List<String> hosts = const []}) =>
    jsonEncode({
      ...jsonDecode(
        File('test/fixtures/sources/declarative_comic.json').readAsStringSync(),
      ) as Map,
      'version': version,
      'allowedHosts': hosts,
    });

void main() {
  late AppDatabase db;
  late ProviderContainer container;
  late SourceRegistry registry;

  setUp(() {
    db = openTestDatabase();
    container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );
    registry = container.read(sourceRegistryProvider);
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  /// 注册表变化经数据库流异步到达：轮询直到 [done] 成立（最多 3 秒）。
  Future<void> eventually(Future<bool> Function() done) async {
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (!await done()) {
      if (DateTime.now().isAfter(deadline)) fail('condition not met in time');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  test('builds clients from the installed manifest', () async {
    await registry.importText(manifest(hosts: ['img.example.com']));
    final clients = container.read(imageHttpClientsProvider);
    final client = await clients.clientFor('com.example.comic');
    expect(
      client.config.hostPolicy.isAllowed(Uri.parse('https://img.example.com')),
      isTrue,
    );
    expect(await clients.clientFor('com.example.comic'), same(client));
  });

  test('unknown sources fail and are not cached', () async {
    final clients = container.read(imageHttpClientsProvider);
    await expectLater(
      clients.clientFor('com.example.missing'),
      throwsA(isA<SourceException>()),
    );
    await registry.importText(
      manifest().replaceAll('com.example.comic', 'com.example.missing'),
    );
    expect(await clients.clientFor('com.example.missing'), isNotNull);
  });

  test('a manifest upgrade replaces the cached client', () async {
    await registry.importText(manifest(hosts: ['img.example.com']));
    final clients =
        container.read(imageHttpClientsProvider) as RegistryImageHttpClients;
    clients.closeDelay = Duration.zero;
    final old = await clients.clientFor('com.example.comic');

    await registry.importText(
      manifest(version: '1.1.0', hosts: ['img.example.com', 'cdn.example.com']),
    );
    await eventually(
      () async => !identical(await clients.clientFor('com.example.comic'), old),
    );

    final fresh = await clients.clientFor('com.example.comic');
    expect(
      fresh.config.hostPolicy.isAllowed(Uri.parse('https://cdn.example.com')),
      isTrue,
    );
  });

  test('removing a source drops its client', () async {
    await registry.importText(manifest());
    final clients =
        container.read(imageHttpClientsProvider) as RegistryImageHttpClients;
    clients.closeDelay = Duration.zero;
    await clients.clientFor('com.example.comic');
    await registry.remove('com.example.comic');
    await eventually(
      () => clients
          .clientFor('com.example.comic')
          .then((_) => false, onError: (Object e) => e is SourceException),
    );
  });
}
