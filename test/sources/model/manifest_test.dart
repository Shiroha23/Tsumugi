import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/sources/model/common.dart';
import 'package:tsumugi/sources/model/manifest.dart';

Map<String, dynamic> _fixture(String name) =>
    jsonDecode(File('test/fixtures/sources/$name').readAsStringSync())
        as Map<String, dynamic>;

void main() {
  group('SourceManifest', () {
    test('解析声明式示例源，并忽略未知字段', () {
      final m = SourceManifest.fromJson(_fixture('declarative_comic.json'));

      expect(m.id, 'com.example.comic');
      expect(m.type, MediaType.comic);
      expect(m.engine, SourceEngine.declarative);
      expect(m.allowedHosts, ['*.example-cdn.com']);
      expect(m.rateLimit, const RateLimit(requests: 5, perSeconds: 1));
      expect(m.timeoutMs, 15000);
      expect(m.settings.single.defaultValue, 'high');
      expect(m.rules?['search'], isNotNull);
      expect(m.validate(), isEmpty);
    });

    SourceManifest base({
      int apiVersion = 1,
      String id = 'com.example.x',
      String baseUrl = 'https://example.com',
      SourceEngine engine = SourceEngine.script,
      String? script = 'export async function search() {}',
    }) => SourceManifest(
      apiVersion: apiVersion,
      id: id,
      name: 'x',
      type: MediaType.novel,
      version: '1.0.0',
      baseUrl: baseUrl,
      engine: engine,
      script: script,
    );

    test('合法脚本源通过校验', () {
      expect(base().validate(), isEmpty);
    });

    test('校验失败项', () {
      expect(base(apiVersion: 99).validate(), hasLength(1));
      expect(base(id: 'Bad ID').validate(), hasLength(1));
      expect(base(baseUrl: '/relative').validate(), hasLength(1));
      expect(base(baseUrl: 'file:///x').validate(), hasLength(1));
      expect(base(script: '  ').validate(), hasLength(1));
      expect(base(engine: SourceEngine.declarative).validate(), hasLength(1));
    });
  });
}
