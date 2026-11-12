import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/network/network_exception.dart';
import 'package:tsumugi/core/network/source_http_client.dart';

NetResponse response(List<int> bytes, {String? contentType}) => NetResponse(
  status: 200,
  url: Uri.parse('http://example.com/'),
  headersAll: {
    if (contentType != null) 'content-type': [contentType],
    'x-multi': ['a', 'b'],
  },
  bytes: Uint8List.fromList(bytes),
);

void main() {
  test('默认按 UTF-8 解码并去掉 BOM', () {
    final r = response([0xEF, 0xBB, 0xBF, ...utf8.encode('中文')]);
    expect(r.text, '中文');
  });

  test('按 charset 解码 latin1', () {
    final r = response([0xE9], contentType: 'text/html; charset=ISO-8859-1');
    expect(r.text, 'é');
  });

  test('多值响应头以 ", " 连接', () {
    expect(response([]).headers['x-multi'], 'a, b');
    expect(response([]).header('X-Multi'), 'a, b');
  });

  test('json() 失败抛出 decode', () {
    expect(
      () => response(utf8.encode('{oops')).json(),
      throwsA(
        isA<NetworkException>().having(
          (e) => e.kind,
          'kind',
          NetworkErrorKind.decode,
        ),
      ),
    );
  });
}
