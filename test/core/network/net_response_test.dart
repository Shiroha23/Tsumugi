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

  test('按 charset 解码 GBK；latin1 标签按 windows-1252', () {
    final gbk = [0xD6, 0xD0, 0xCE, 0xC4];
    expect(response(gbk, contentType: 'text/html; charset=gb2312').text, '中文');
    expect(
      response([0x80], contentType: 'text/plain; charset=latin1').text,
      '€',
    );
  });

  test('BOM 优先于 Content-Type', () {
    final r = response([
      0xEF,
      0xBB,
      0xBF,
      ...utf8.encode('中'),
    ], contentType: 'text/html; charset=iso-8859-1');
    expect(r.text, '中');
  });

  test('json() 可显式指定 charset', () {
    final body = [0x7B, 0x22, 0x61, 0x22, 0x3A, 0x22, 0xD6, 0xD0, 0x22, 0x7D];
    final r = response(body, contentType: 'application/json');
    expect(r.json(charset: 'gbk'), {'a': '中'});
    expect((r.json() as Map)['a'], '��');
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
