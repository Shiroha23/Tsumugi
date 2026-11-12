import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/export.dart';

import '../script_runtime.dart';

/// `tsumugi.crypto`（docs/source-spec.md §4.2）的同步实现，在 worker isolate 内执行。
///
/// 约定：字符串参数按 UTF-8 编码为字节；摘要返回小写十六进制。
/// AES 的 `key` / `iv` 默认按 UTF-8，可用 `keyEncoding` / `ivEncoding`（`utf8` | `hex` | `base64`）指定；
/// 密文按 `encoding`（默认 `base64`）编码；明文按 UTF-8。CBC / ECB 使用 PKCS#7 填充，
/// GCM 的认证标签（128 位）附在密文末尾。
/// 参数非法 → 普通 JS 异常；解密失败（填充 / 标签校验 / 编码错误，含明文不是合法 UTF-8）→ `E_PARSE`。
Map<String, HostFunction> cryptoHostFunctions() => {
  'crypto.md5': (a) => crypto.md5.convert(_utf8(a, 0)).toString(),
  'crypto.sha1': (a) => crypto.sha1.convert(_utf8(a, 0)).toString(),
  'crypto.sha256': (a) => crypto.sha256.convert(_utf8(a, 0)).toString(),
  'crypto.hmacSha256': (a) =>
      crypto.Hmac(crypto.sha256, _utf8(a, 0)).convert(_utf8(a, 1)).toString(),
  'crypto.base64Encode': (a) => base64.encode(_utf8(a, 0)),
  'crypto.base64Decode': (a) {
    try {
      return utf8.decode(base64.decode(base64.normalize(_str(a, 0).trim())));
    } on FormatException catch (e) {
      throw ScriptException('base64Decode: ${e.message}', code: _parse);
    }
  },
  'crypto.aesEncrypt': (a) {
    final o = _AesOptions.parse(a);
    final out = o.run(encrypt: true, input: utf8.encode(o.data));
    return o.encoding == 'hex' ? _hex(out) : base64.encode(out);
  },
  'crypto.aesDecrypt': (a) {
    final o = _AesOptions.parse(a);
    final Uint8List input;
    try {
      input = o.encoding == 'hex'
          ? _unhex(o.data)
          : base64.decode(base64.normalize(o.data.trim()));
    } on FormatException catch (e) {
      throw ScriptException('aesDecrypt: ${e.message}', code: _parse);
    }
    final plain = o.run(encrypt: false, input: input);
    try {
      return utf8.decode(plain);
    } on FormatException {
      throw const ScriptException(
        'aesDecrypt: plaintext is not valid UTF-8.',
        code: _parse,
      );
    }
  },
};

const _parse = 'E_PARSE';

String _str(List<Object?> args, int i) {
  final v = i < args.length ? args[i] : null;
  if (v is! String) {
    throw ScriptException('Argument ${i + 1} must be a string.');
  }
  return v;
}

Uint8List _utf8(List<Object?> args, int i) => utf8.encode(_str(args, i));

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List _unhex(String s) {
  final t = s.trim();
  if (t.length.isOdd || !RegExp(r'^[0-9a-fA-F]*$').hasMatch(t)) {
    throw const FormatException('invalid hex');
  }
  return Uint8List.fromList([
    for (var i = 0; i < t.length; i += 2)
      int.parse(t.substring(i, i + 2), radix: 16),
  ]);
}

class _AesOptions {
  _AesOptions(this.data, this.key, this.iv, this.mode, this.encoding);

  final String data;
  final Uint8List key;
  final Uint8List? iv;
  final String mode;
  final String encoding;

  static _AesOptions parse(List<Object?> args) {
    final o = args.isEmpty ? null : args[0];
    if (o is! Map) {
      throw const ScriptException('AES options must be an object.');
    }
    String req(String k) {
      final v = o[k];
      if (v is! String) {
        throw ScriptException('AES option "$k" must be a string.');
      }
      return v;
    }

    String? opt(String k) {
      final v = o[k];
      if (v == null) return null;
      if (v is! String) {
        throw ScriptException('AES option "$k" must be a string.');
      }
      return v;
    }

    Uint8List bytes(String value, String? enc, String name) {
      try {
        return switch (enc ?? 'utf8') {
          'utf8' => utf8.encode(value),
          'hex' => _unhex(value),
          'base64' => base64.decode(base64.normalize(value.trim())),
          final e => throw ScriptException('Unknown $name encoding "$e".'),
        };
      } on FormatException catch (e) {
        throw ScriptException('Invalid $name: ${e.message}');
      }
    }

    final mode = req('mode').toUpperCase();
    if (!const {'CBC', 'ECB', 'GCM'}.contains(mode)) {
      throw ScriptException('Unsupported AES mode "$mode".');
    }
    final encoding = (opt('encoding') ?? 'base64').toLowerCase();
    if (encoding != 'base64' && encoding != 'hex') {
      throw ScriptException('Unsupported encoding "$encoding".');
    }
    final key = bytes(req('key'), opt('keyEncoding'), 'key');
    if (!const {16, 24, 32}.contains(key.length)) {
      throw ScriptException(
        'AES key must be 16, 24 or 32 bytes (got ${key.length}).',
      );
    }
    final ivText = opt('iv');
    final iv = ivText == null ? null : bytes(ivText, opt('ivEncoding'), 'iv');
    switch (mode) {
      case 'CBC' when iv?.length != 16:
        throw const ScriptException('CBC mode requires a 16-byte iv.');
      case 'GCM' when iv == null || iv.isEmpty:
        throw const ScriptException('GCM mode requires an iv.');
    }
    return _AesOptions(req('data'), key, iv, mode, encoding);
  }

  Uint8List run({required bool encrypt, required Uint8List input}) {
    try {
      switch (mode) {
        case 'GCM':
          final cipher = GCMBlockCipher(AESEngine())
            ..init(
              encrypt,
              AEADParameters(KeyParameter(key), 128, iv!, Uint8List(0)),
            );
          return cipher.process(input);
        case 'CBC':
          final cipher =
              PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))
                ..init(
                  encrypt,
                  PaddedBlockCipherParameters(
                    ParametersWithIV(KeyParameter(key), iv!),
                    null,
                  ),
                );
          return cipher.process(input);
        default: // ECB
          final cipher =
              PaddedBlockCipherImpl(PKCS7Padding(), ECBBlockCipher(AESEngine()))
                ..init(
                  encrypt,
                  PaddedBlockCipherParameters(KeyParameter(key), null),
                );
          return cipher.process(input);
      }
    } on ScriptException {
      rethrow;
    } on Object catch (e) {
      // pointycastle 用 ArgumentError / InvalidCipherTextException 等报告填充或标签错误。
      throw ScriptException(
        'AES ${encrypt ? 'encryption' : 'decryption'} failed: $e',
        code: _parse,
      );
    }
  }
}
