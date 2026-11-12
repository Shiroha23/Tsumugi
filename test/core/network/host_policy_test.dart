import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/core/network/host_policy.dart';

void main() {
  final policy = HostPolicy(
    baseUrl: Uri.parse('https://example.com'),
    allowedHosts: ['img.example.org', '*.example-cdn.com'],
  );

  bool allowed(String url) => policy.isAllowed(Uri.parse(url));

  test('允许 baseUrl 主机（忽略大小写）', () {
    expect(allowed('https://example.com/a'), isTrue);
    expect(allowed('http://EXAMPLE.com/a'), isTrue);
  });

  test('允许精确列出的主机', () {
    expect(allowed('https://img.example.org/1.jpg'), isTrue);
  });

  test('通配符匹配任意层级子域名，但不匹配根域名', () {
    expect(allowed('https://a.example-cdn.com/x'), isTrue);
    expect(allowed('https://a.b.example-cdn.com/x'), isTrue);
    expect(allowed('https://example-cdn.com/x'), isFalse);
  });

  test('拒绝白名单外的主机与相似后缀', () {
    expect(allowed('https://evil.com'), isFalse);
    expect(allowed('https://notexample.com'), isFalse);
    expect(allowed('https://xexample-cdn.com'), isFalse);
    expect(allowed('https://example.com.evil.com'), isFalse);
  });

  test('拒绝非 http(s) scheme', () {
    expect(allowed('file:///etc/passwd'), isFalse);
    expect(allowed('ftp://example.com'), isFalse);
  });
}
