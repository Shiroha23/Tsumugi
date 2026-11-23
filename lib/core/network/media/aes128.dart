import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// HLS `METHOD=AES-128` 分片的解密（AES-128-CBC + PKCS7，RFC 8216 §5.2）。
///
/// 本地媒体代理（播放时）与视频下载（下载时解密、存明文，architecture §4.5.1）共用。
/// 长度不是 16 的倍数、填充错误（密钥 / IV 不对）时抛出异常。
Uint8List decryptHlsAes128(Uint8List cipherText, Uint8List key, Uint8List iv) {
  final cipher =
      PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))..init(
        false,
        PaddedBlockCipherParameters(
          ParametersWithIV(KeyParameter(key), iv),
          null,
        ),
      );
  return cipher.process(cipherText);
}
