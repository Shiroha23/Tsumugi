import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/network/host_name.dart';

void main() {
  test('Punycode 编码与公开测试向量一致', () {
    expect(punycodeEncode('bücher'), 'bcher-kva');
    expect(punycodeEncode('münchen'), 'mnchen-3ya');
    expect(punycodeEncode('中国'), 'fiqs8s');
    expect(punycodeEncode('中國'), 'fiqz9s');
    expect(punycodeEncode('测试'), '0zwm56d');
  });

  test('normalizeHost', () {
    expect(normalizeHost('Example.COM.'), 'example.com');
    expect(
      normalizeHost('b%C3%BCcher.example.com'),
      'xn--bcher-kva.example.com',
    );
    expect(normalizeHost('Bücher.Example.com'), 'xn--bcher-kva.example.com');
    expect(normalizeHost('[::1]'), '::1');
    expect(normalizeHost('127.0.0.1'), '127.0.0.1');
    expect(normalizeHost(''), isNull);
    expect(normalizeHost('.'), isNull);
    expect(normalizeHost('a..b'), isNull);
    expect(normalizeHost('%zz'), isNull);
    expect(normalizeHost('%FF.example.com'), isNull);
  });
}
