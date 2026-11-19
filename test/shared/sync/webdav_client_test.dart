import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/shared/sync/sync_document.dart';
import 'package:tsumugi/shared/sync/sync_exception.dart';
import 'package:tsumugi/shared/sync/webdav_client.dart';

import 'sync_test_support.dart';

Matcher _syncError(SyncError error) =>
    throwsA(isA<SyncException>().having((e) => e.error, 'error', error));

void main() {
  group('server url', () {
    test('only https, loopback may use http', () {
      expect(
        parseServerUrl('https://dav.example.com/remote.php/dav').toString(),
        'https://dav.example.com/remote.php/dav/',
      );
      expect(parseServerUrl('http://127.0.0.1:8080').path, '/');
      expect(parseServerUrl('http://localhost/dav/').host, 'localhost');
      expect(parseServerUrl('http://[::1]:9/').host, '::1');
      expect(
        () => parseServerUrl('http://dav.example.com/'),
        _syncError(SyncError.invalidConfig),
      );
      expect(
        () => parseServerUrl('ftp://dav.example.com/'),
        _syncError(SyncError.invalidConfig),
      );
      expect(() => parseServerUrl('dav'), _syncError(SyncError.invalidConfig));
    });

    test('credentials, query and fragment are rejected', () {
      for (final bad in [
        'https://alice:secret@dav.example.com/',
        'https://alice@dav.example.com/',
        'https://dav.example.com/?a=1',
        'https://dav.example.com/#x',
      ]) {
        expect(
          () => parseServerUrl(bad),
          _syncError(SyncError.invalidConfig),
          reason: bad,
        );
      }
    });

    test('remote dir is normalized and cannot escape', () {
      expect(parseRemoteDir('/a//b/'), ['a', 'b']);
      expect(parseRemoteDir(''), isEmpty);
      expect(formatRemoteDir(parseRemoteDir('Tsumugi')), 'Tsumugi/');
      for (final bad in ['../x', 'a/./b', r'a\b', 'a/ b']) {
        expect(
          () => parseRemoteDir(bad),
          _syncError(SyncError.invalidConfig),
          reason: bad,
        );
      }
      final config = WebDavConfig(
        serverUrl: 'https://dav.example.com/dav',
        username: 'u',
        password: 'p',
        remoteDir: '同步 目录/a#b',
      );
      expect(
        config.fileUri.toString(),
        'https://dav.example.com/dav/%E5%90%8C%E6%AD%A5%20%E7%9B%AE%E5%BD%95/a%23b/sync-v1.json',
      );
    });
  });

  group('against the mock server', () {
    late MockServer server;

    setUp(() async => server = await MockServer.start());
    tearDown(() => server.close());

    WebDavClient client({String password = MockWebDav.password}) =>
        WebDavClient(
          WebDavConfig(
            serverUrl: davUrl(server),
            username: MockWebDav.username,
            password: password,
            remoteDir: 'a/b/',
          ),
          adapter: mockAdapter(server),
        );

    test('basic auth and status mapping', () async {
      final c = client();
      addTearDown(c.close);
      expect(await c.get(), isA<WebDavNotFound>());
      expect(
        server.requests.single.headers['authorization'],
        'Basic ${base64Encode(utf8.encode('alice:secret'))}',
      );
      final bad = client(password: 'nope');
      addTearDown(bad.close);
      await expectLater(bad.get(), _syncError(SyncError.auth));
      await expectLater(bad.checkConnection(), _syncError(SyncError.auth));
    });

    test('nested directories, conditional put and get', () async {
      final c = client();
      addTearDown(c.close);
      await c.ensureDirectory();
      expect(server.dav.collections, containsAll(['/a/', '/a/b/']));
      // 已存在时只 PROPFIND，不再 MKCOL。
      server.requests.clear();
      await c.ensureDirectory();
      expect(server.requests.map((r) => r.method), ['PROPFIND', 'PROPFIND']);

      final etag = await c.put(Uint8List.fromList([1]), createOnly: true);
      expect(etag, isNotNull);
      await expectLater(
        c.put(Uint8List.fromList([2]), createOnly: true),
        throwsA(isA<WebDavPreconditionFailed>()),
      );
      await expectLater(
        c.put(Uint8List.fromList([2]), ifMatch: '"stale"'),
        throwsA(isA<WebDavPreconditionFailed>()),
      );
      final etag2 = await c.put(Uint8List.fromList([3]), ifMatch: etag);
      expect(etag2, isNot(etag));

      expect(await c.get(ifNoneMatch: etag2), isA<WebDavNotModified>());
      final file = await c.get(ifNoneMatch: etag) as WebDavFile;
      expect(file.bytes, [3]);
      expect(file.etag, etag2);
    });

    test('put into a missing directory creates it once', () async {
      final c = client();
      addTearDown(c.close);
      await c.put(Uint8List.fromList([1]), createOnly: true);
      expect(server.dav.files.keys, ['/a/b/sync-v1.json']);
    });

    test('redirects are not followed', () async {
      final c = WebDavClient(
        WebDavConfig(
          serverUrl: '${server.origin}/dav/moved/',
          username: MockWebDav.username,
          password: MockWebDav.password,
          remoteDir: '',
        ),
        adapter: mockAdapter(server),
      );
      addTearDown(c.close);
      await expectLater(c.get(), _syncError(SyncError.server));
      expect(server.requests, hasLength(1));
    });

    test('the whole request is bounded by the request timeout', () async {
      final c = WebDavClient(
        WebDavConfig(
          serverUrl: '${server.origin}/dav/stall/',
          username: MockWebDav.username,
          password: MockWebDav.password,
          remoteDir: '',
        ),
        adapter: mockAdapter(server),
        requestTimeout: const Duration(milliseconds: 400),
      );
      addTearDown(c.close);
      final watch = Stopwatch()..start();
      // 响应体每 50 ms 才来 1 字节：空闲超时不会触发，只有总时限能结束它。
      await expectLater(c.get(), _syncError(SyncError.network));
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
    });

    test(
      'uploads carry Content-Length and refuse transfer compression',
      () async {
        final c = client();
        addTearDown(c.close);
        await c.put(Uint8List.fromList([1, 2, 3]), createOnly: true);
        final put = server.requests.lastWhere((r) => r.method == 'PUT');
        expect(put.headers['content-length'], '3');
        expect(put.headers['transfer-encoding'], isNull);
        expect(put.headers['accept-encoding'], 'identity');
      },
    );

    test('weak ETags are not used for conditional requests', () async {
      server.dav.weakEtags = true;
      final c = client();
      addTearDown(c.close);
      expect(await c.put(Uint8List.fromList([1]), createOnly: true), isNull);
      final file = await c.get() as WebDavFile;
      expect(file.etag, isNull);
    });

    test('download size is limited', () async {
      server.dav.collections.add('/a/');
      server.dav.collections.add('/a/b/');
      server.dav.files['/a/b/sync-v1.json'] = (
        bytes: Uint8List(maxSyncFileBytes + 1),
        etag: '"big"',
      );
      final c = client();
      addTearDown(c.close);
      await expectLater(c.get(), _syncError(SyncError.tooLarge));
    });
  });

  group('sync document', () {
    test('round trip keeps unknown collections and fields', () {
      final raw = {
        'syncVersion': 1,
        'futureTop': 1,
        'collections': {
          'library': [
            {
              'key': ['s', 'i'],
              'modifiedAt': 5,
              'deviceId': 'd',
              'deleted': false,
              'data': {'title': 't', 'futureField': true},
              'futureRecordField': 'x',
            },
          ],
          'bookmarks': [
            {'anything': 1},
          ],
        },
      };
      final doc = SyncDocument.fromJson(raw);
      expect(doc.hadInvalidRecords, isFalse);
      final back = doc.toJson();
      expect(back['futureTop'], 1);
      final collections = back['collections']! as Map;
      expect(
        collections['bookmarks'],
        (raw['collections']! as Map)['bookmarks'],
      );
      final record = (collections['library'] as List).single as Map;
      expect(record['futureRecordField'], 'x');
      expect((record['data'] as Map)['futureField'], isTrue);
      // 编码后可再解压解析。
      final decoded = SyncDocument.decode(doc.encode());
      expect(decoded.collections['library'], hasLength(1));
    });

    test('invalid and duplicate records are dropped and flagged', () {
      final doc = SyncDocument.fromJson({
        'syncVersion': 1,
        'collections': {
          'library': [
            {
              'key': ['only-one'],
              'modifiedAt': 1,
              'deviceId': 'd',
              'data': {},
            },
            {
              'key': ['s', 'i'],
              'modifiedAt': '1',
              'deviceId': 'd',
              'data': {},
            },
            {
              'key': ['s', 'i'],
              'modifiedAt': 1,
              'deviceId': '',
              'data': {},
            },
            {
              'key': ['s', 'i'],
              'modifiedAt': 1,
              'deviceId': 'd',
            },
            {
              'key': ['s', 'i'],
              'modifiedAt': 1,
              'deviceId': 'd',
              'data': {'v': 1},
            },
            {
              'key': ['s', 'i'],
              'modifiedAt': 2,
              'deviceId': 'd',
              'data': {'v': 2},
            },
          ],
          'sources': 'not a list',
        },
      });
      expect(doc.hadInvalidRecords, isTrue);
      expect(doc.collections['library']!.values.single.data, {'v': 2});
      expect(doc.collections.containsKey('sources'), isFalse);
    });

    test('deeply nested JSON is rejected', () {
      var nested = '1';
      for (var i = 0; i < 100; i++) {
        nested = '[$nested]';
      }
      final text = '{"syncVersion":1,"collections":{"x":$nested}}';
      expect(
        () => SyncDocument.decode(gzip.encode(utf8.encode(text))),
        _syncError(SyncError.badFormat),
      );
      expect(jsonDepth(List.filled(3, [1])), 2);
    });

    test('format errors', () {
      expect(
        () => SyncDocument.decode(utf8.encode('{"syncVersion":1}')),
        _syncError(SyncError.badFormat),
      );
      expect(
        () => SyncDocument.decode(gzip.encode(utf8.encode('[1]'))),
        _syncError(SyncError.badFormat),
      );
      expect(
        () => SyncDocument.decode(
          gzip.encode(utf8.encode('{"syncVersion":9,"collections":{}}')),
        ),
        _syncError(SyncError.unsupportedVersion),
      );
      expect(
        () => SyncDocument.decode([0x1f, 0x8b, 1, 2, 3]),
        _syncError(SyncError.badFormat),
      );
    });

    test('decompression stops at the limit (gzip bomb)', () {
      final bomb = gzip.encode(Uint8List(maxSyncFileBytes + 1024));
      expect(bomb.length, lessThan(100 * 1024));
      expect(() => gunzipLimited(bomb), _syncError(SyncError.tooLarge));
      expect(gunzipLimited(gzip.encode([1, 2, 3])), [1, 2, 3]);
    });
  });
}
