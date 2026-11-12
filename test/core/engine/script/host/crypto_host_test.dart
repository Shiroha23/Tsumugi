import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:tsumugi/core/engine/script/host/crypto_host.dart';
import 'package:tsumugi/core/engine/script/script_runtime.dart';

void main() {
  final fns = cryptoHostFunctions();
  const key = '0123456789abcdef';

  String ecbEncryptBytes(List<int> plain) {
    final cipher =
        PaddedBlockCipherImpl(PKCS7Padding(), ECBBlockCipher(AESEngine()))
          ..init(
            true,
            PaddedBlockCipherParameters(
              KeyParameter(Uint8List.fromList(utf8.encode(key))),
              null,
            ),
          );
    return base64.encode(cipher.process(Uint8List.fromList(plain)));
  }

  test('aesDecrypt: valid padding but non-UTF-8 plaintext → E_PARSE', () {
    final data = ecbEncryptBytes([0xff]);
    expect(
      () => fns['crypto.aesDecrypt']!([
        {'data': data, 'key': key, 'mode': 'ECB'},
      ]),
      throwsA(
        isA<ScriptException>()
            .having((e) => e.code, 'code', 'E_PARSE')
            .having((e) => e.message, 'message', contains('UTF-8')),
      ),
    );
    // 合法 UTF-8 明文照常返回。
    expect(
      fns['crypto.aesDecrypt']!([
        {'data': ecbEncryptBytes(utf8.encode('纸鹤')), 'key': key, 'mode': 'ECB'},
      ]),
      '纸鹤',
    );
  });

  test('base64Decode: non-UTF-8 bytes → E_PARSE', () {
    expect(
      () => fns['crypto.base64Decode']!([
        base64.encode([0xff, 0xfe]),
      ]),
      throwsA(isA<ScriptException>().having((e) => e.code, 'code', 'E_PARSE')),
    );
  });
}
