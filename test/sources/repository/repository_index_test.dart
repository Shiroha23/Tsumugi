import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/sources/model/common.dart';
import 'package:tsumugi/sources/repository/providers.dart';

final _base = Uri.parse('https://repo.example.com/sub/index.json');

Map<String, Object?> _entry([Map<String, Object?> changes = const {}]) => {
  'id': 'com.example.a',
  'name': 'A',
  'type': 'comic',
  'version': '1.0.0',
  'apiVersion': 1,
  'url': 'sources/a.json',
  'sha256': 'a' * 64,
  ...changes,
};

RepositoryIndex _parse(Object? json) =>
    parseRepositoryIndex(utf8.encode(jsonEncode(json)), _base);

Map<String, Object?> _index(List<Object?> sources) => {
  'repoVersion': 1,
  'name': '仓库',
  'sources': sources,
};

Matcher _throwsKind(RepositoryErrorKind kind) =>
    throwsA(isA<RepositoryException>().having((e) => e.kind, 'kind', kind));

void main() {
  group('normalizeRepositoryUrl', () {
    test('小写协议与主机、去片段与默认端口', () {
      expect(
        normalizeRepositoryUrl(' HTTPS://Repo.Example.COM:443/a/index.json#x ')
            .toString(),
        'https://repo.example.com/a/index.json',
      );
    });

    test('目录地址补 index.json', () {
      expect(
        normalizeRepositoryUrl('https://repo.example.com').toString(),
        'https://repo.example.com/index.json',
      );
      expect(
        normalizeRepositoryUrl('https://repo.example.com/r/').toString(),
        'https://repo.example.com/r/index.json',
      );
    });

    test('保留非默认端口与查询', () {
      expect(
        normalizeRepositoryUrl('https://repo.example.com:8443/i.json?v=1')
            .toString(),
        'https://repo.example.com:8443/i.json?v=1',
      );
    });

    test('拒绝 http（回环地址除外）、其他协议、用户信息与不完整地址', () {
      for (final bad in [
        'http://repo.example.com/index.json',
        'ftp://repo.example.com/index.json',
        'https://user:pass@repo.example.com/index.json',
      ]) {
        expect(
          () => normalizeRepositoryUrl(bad),
          _throwsKind(RepositoryErrorKind.insecureUrl),
          reason: bad,
        );
      }
      expect(
        () => normalizeRepositoryUrl('repo.example.com/index.json'),
        _throwsKind(RepositoryErrorKind.invalidUrl),
      );
      expect(
        () => normalizeRepositoryUrl('file:///c:/index.json'),
        _throwsKind(RepositoryErrorKind.invalidUrl),
      );
      for (final ok in [
        'http://127.0.0.1:8080/index.json',
        'http://localhost/index.json',
        'http://[::1]:8080/index.json',
      ]) {
        // 默认（应用中）拒绝；只有测试显式开启时允许。
        expect(
          () => normalizeRepositoryUrl(ok),
          _throwsKind(RepositoryErrorKind.insecureUrl),
          reason: ok,
        );
        expect(
          normalizeRepositoryUrl(ok, allowLoopbackHttp: true).scheme,
          'http',
          reason: ok,
        );
      }
    });

    test('回环例外默认关闭；开启时也只限三个地址', () {
      bool allowed(String u) =>
          isAllowedRepositoryUri(Uri.parse(u), allowLoopbackHttp: true);
      expect(isAllowedRepositoryUri(Uri.parse('http://127.0.0.1/')), isFalse);
      expect(isAllowedRepositoryUri(Uri.parse('http://[::1]/')), isFalse);
      expect(allowed('http://127.0.0.1/'), isTrue);
      expect(allowed('http://[::1]/'), isTrue);
      expect(allowed('http://127.0.0.2/'), isFalse);
      expect(allowed('http://localhost.example.com/'), isFalse);
    });

    test('发布版拒绝指向本机的 https 地址（重定向与条目同一判断）', () {
      for (final u in [
        'https://localhost/x',
        'https://LOCALHOST./x',
        'https://a.localhost/x',
        'https://127.0.0.1:8443/x',
        'https://127.1.2.3/x',
        'https://0.0.0.0/x',
        'https://[::1]/x',
        'https://[::]/x',
        'https://[::ffff:127.0.0.1]/x',
      ]) {
        expect(isAllowedRepositoryUri(Uri.parse(u)), isFalse, reason: u);
      }
      expect(
        isAllowedRepositoryUri(Uri.parse('https://127.example.com/')),
        isTrue,
      );
      expect(isLocalHost('localhost.example.com'), isFalse);
      expect(
        () => _parse(
          _index([
            _entry({'url': 'https://localhost:631/a.json'}),
          ]),
        ),
        _throwsKind(RepositoryErrorKind.invalidIndex),
      );
    });

    test('默认配置下索引条目不能指向回环 http', () {
      expect(
        () => _parse(
          _index([
            _entry({'url': 'http://127.0.0.1:631/a.json'}),
          ]),
        ),
        _throwsKind(RepositoryErrorKind.invalidIndex),
      );
    });
  });

  group('parseRepositoryIndex', () {
    test('合法索引：相对 url 按 index.json 解析，忽略未知字段', () {
      final index = _parse({
        ..._index([
          _entry({'lang': 'zh', 'nsfw': true, 'future': 1}),
          _entry({
            'id': 'com.example.b',
            'type': 'novel',
            'apiVersion': 2,
            'url': 'https://cdn.example.com/b.json',
          }),
        ]),
        'extra': true,
      });
      expect(index.name, '仓库');
      expect(index.entries, hasLength(2));
      final a = index.entry('com.example.a')!;
      expect(a.url.toString(), 'https://repo.example.com/sub/sources/a.json');
      expect(a.lang, 'zh');
      expect(a.nsfw, isTrue);
      expect(a.apiSupported, isTrue);
      final b = index.entry('com.example.b')!;
      expect(b.type, MediaType.novel);
      expect(b.nsfw, isFalse);
      expect(b.apiSupported, isFalse);
    });

    test('sha256 按原始字节计算', () {
      final bytes = utf8.encode(jsonEncode(_index([])));
      expect(
        parseRepositoryIndex(bytes, _base).sha256,
        sha256.convert(bytes).toString(),
      );
    });

    test('repoVersion 过高：需要更新客户端', () {
      expect(
        () => _parse({...(_index([])), 'repoVersion': 2}),
        _throwsKind(RepositoryErrorKind.unsupportedRepoVersion),
      );
    });

    test('id 重复时整个索引无效', () {
      expect(
        () => _parse(
          _index([
            _entry(),
            _entry({'name': 'B'}),
          ]),
        ),
        _throwsKind(RepositoryErrorKind.invalidIndex),
      );
    });

    test('字段错误时整个索引无效', () {
      final cases = <String, Object?>{
        '非 JSON': null,
        '缺 name': {'repoVersion': 1, 'sources': []},
        '缺 sources': {'repoVersion': 1, 'name': 'x'},
        '缺 repoVersion': {'name': 'x', 'sources': []},
        '条目缺 id': _index([
          {..._entry()}..remove('id'),
        ]),
        '条目缺 sha256': _index([
          {..._entry()}..remove('sha256'),
        ]),
        '条目缺 version': _index([
          {..._entry()}..remove('version'),
        ]),
        'sha256 大写': _index([
          _entry({'sha256': 'A' * 64}),
        ]),
        'sha256 长度不对': _index([
          _entry({'sha256': 'a' * 63}),
        ]),
        'type 未知': _index([
          _entry({'type': 'podcast'}),
        ]),
        'apiVersion 非整数': _index([
          _entry({'apiVersion': '1'}),
        ]),
        'url 为 http': _index([
          _entry({'url': 'http://cdn.example.com/a.json'}),
        ]),
        'url 为 data:': _index([
          _entry({'url': 'data:application/json,{}'}),
        ]),
        'nsfw 非布尔': _index([
          _entry({'nsfw': 'yes'}),
        ]),
        '条目不是对象': _index(['x']),
      };
      for (final MapEntry(:key, :value) in cases.entries) {
        expect(
          () => value == null
              ? parseRepositoryIndex(utf8.encode('{oops'), _base)
              : _parse(value),
          _throwsKind(RepositoryErrorKind.invalidIndex),
          reason: key,
        );
      }
    });

    test('https 索引中的相对 url 不会变成 http', () {
      final index = _parse(
        _index([
          _entry({'url': '//cdn.example.com/a.json'}),
        ]),
      );
      expect(index.entries.single.url.scheme, 'https');
    });
  });

  test('测试数据中的 sha256 与清单字节一致（bad-hash 条目除外）', () {
    for (final dir in ['good', 'flow-v1', 'flow-v2']) {
      final indexFile = File('test/fixtures/repository/$dir/index.json');
      final index = parseRepositoryIndex(
        indexFile.readAsBytesSync(),
        Uri.parse('https://repo.example.com/repo/$dir/index.json'),
      );
      for (final e in index.entries) {
        if (!e.url.path.startsWith('/repo/$dir/sources/')) continue;
        final file = File(
          'test/fixtures/repository/$dir/${e.url.path.substring('/repo/$dir/'.length)}',
        );
        if (!file.existsSync()) continue; // 故意不存在的条目（如 apiVersion 过高）
        final actual = sha256.convert(file.readAsBytesSync()).toString();
        if (e.id == 'com.example.repo.badhash') {
          expect(actual, isNot(e.sha256));
        } else {
          expect(actual, e.sha256, reason: '${file.path}（是否被换行转换？）');
        }
      }
    }
  });
}
