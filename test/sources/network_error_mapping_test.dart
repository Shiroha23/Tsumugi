import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/network/network_exception.dart';
import 'package:tsumugi/sources/model/manifest.dart';
import 'package:tsumugi/sources/network_error_mapping.dart';
import 'package:tsumugi/sources/source.dart';

void main() {
  test('每个网络错误类别都映射到 source-spec §6 错误码', () {
    const expected = {
      NetworkErrorKind.connection: 'E_NETWORK',
      NetworkErrorKind.timeout: 'E_NETWORK',
      NetworkErrorKind.cancelled: 'E_NETWORK',
      NetworkErrorKind.tooManyRedirects: 'E_NETWORK',
      NetworkErrorKind.invalidRequest: 'E_NETWORK',
      NetworkErrorKind.http: 'E_HTTP',
      NetworkErrorKind.hostNotAllowed: 'E_HOST_NOT_ALLOWED',
      NetworkErrorKind.challenge: 'E_CHALLENGE',
      NetworkErrorKind.decode: 'E_PARSE',
      NetworkErrorKind.responseTooLarge: 'E_LIMIT',
    };
    expect(expected.keys, containsAll(NetworkErrorKind.values));
    for (final MapEntry(:key, :value) in expected.entries) {
      expect(NetworkException(key).sourceErrorCode.wire, value, reason: '$key');
    }
  });

  test('只有 E_HTTP 携带 status', () {
    final http = const NetworkException(
      NetworkErrorKind.http,
      status: 404,
      message: 'HTTP 404',
    ).toSourceException();
    expect(http.code, SourceErrorCode.http);
    expect(http.status, 404);
    expect(http.message, 'HTTP 404');

    final challenge = const NetworkException(
      NetworkErrorKind.challenge,
      status: 403,
    ).toSourceException();
    expect(challenge.code, SourceErrorCode.challenge);
    expect(challenge.status, isNull);
  });

  test('由清单生成网络配置', () {
    final manifest = SourceManifest.fromJson(
      jsonDecode(
        File('test/fixtures/sources/declarative_comic.json').readAsStringSync(),
      ) as Map<String, dynamic>,
    );
    final config = networkConfigFromManifest(manifest);
    expect(config.sourceId, 'com.example.comic');
    expect(config.baseUrl, Uri.parse('https://example.com'));
    expect(config.defaultHeaders, {'Referer': 'https://example.com/'});
    expect(config.timeout, const Duration(milliseconds: 15000));
    expect(config.rateLimit?.requests, 5);
    expect(config.rateLimit?.per, const Duration(seconds: 1));
    final policy = config.hostPolicy;
    expect(policy.isAllowed(Uri.parse('https://a.example-cdn.com/x')), isTrue);
    expect(policy.isAllowed(Uri.parse('https://evil.example.net/')), isFalse);
  });

  test('非正数 rateLimit 视为不限速', () {
    final manifest = SourceManifest.fromJson({
      'apiVersion': 1,
      'id': 'com.example.x',
      'name': 'x',
      'type': 'novel',
      'version': '1.0.0',
      'baseUrl': 'https://example.com',
      'engine': 'script',
      'script': 'export {}',
      'rateLimit': {'requests': 0, 'perSeconds': 1},
    });
    expect(networkConfigFromManifest(manifest).rateLimit, isNull);
  });
}
