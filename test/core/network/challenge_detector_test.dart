import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/network/challenge_detector.dart';

void main() {
  const detector = ChallengeDetector();
  Uint8List body(String s) => Uint8List.fromList(utf8.encode(s));

  test('特征响应头', () {
    expect(
      detector.isChallenge(403, {
        'cf-mitigated': ['Challenge'],
      }, Uint8List(0)),
      isTrue,
    );
  });

  test('特征页面内容（忽略大小写）', () {
    expect(
      detector.isChallenge(503, {}, body('<FORM id="Challenge-Form">')),
      isTrue,
    );
    expect(
      detector.isChallenge(403, {}, body('<div class="g-recaptcha"></div>')),
      isTrue,
    );
  });

  test('只检查指定状态码', () {
    expect(
      detector.isChallenge(200, {
        'cf-mitigated': ['challenge'],
      }, body('challenge-form')),
      isFalse,
    );
  });

  test('没有特征的 403 / 503 不是挑战', () {
    expect(detector.isChallenge(403, {}, body('Forbidden')), isFalse);
    expect(detector.isChallenge(503, {}, Uint8List(0)), isFalse);
  });

  test('只扫描响应体开头', () {
    const d = ChallengeDetector(scanBytes: 16);
    expect(d.isChallenge(503, {}, body('${'x' * 32}challenge-form')), isFalse);
  });
}
