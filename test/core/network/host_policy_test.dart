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

  test('结尾的 DNS 根点视为同一主机', () {
    expect(allowed('https://example.com./a'), isTrue);
    expect(allowed('https://a.example-cdn.com./x'), isTrue);
    expect(
      HostPolicy(
        baseUrl: Uri.parse('https://example.com'),
        allowedHosts: ['IMG.Example.org.'],
      ).isAllowed(Uri.parse('https://img.example.org/')),
      isTrue,
    );
  });

  test('端口与 userinfo 不影响匹配', () {
    expect(allowed('https://user:pw@example.com:8443/a'), isTrue);
    expect(allowed('https://example.com@evil.com/'), isFalse);
  });

  group('国际化域名', () {
    final idn = HostPolicy(
      baseUrl: Uri.parse('https://example.com'),
      allowedHosts: ['bücher.example.com', '*.测试'],
    );
    bool idnAllowed(String url) => idn.isAllowed(Uri.parse(url));

    test('Unicode 白名单匹配 Punycode 请求，反之亦然', () {
      expect(idnAllowed('https://xn--bcher-kva.example.com/'), isTrue);
      expect(idnAllowed('https://Bücher.example.com/'), isTrue);
      expect(idnAllowed('https://a.xn--0zwm56d/'), isTrue);
      expect(idnAllowed('https://a.测试/'), isTrue);
    });

    test('不同的国际化域名仍被拒绝', () {
      expect(idnAllowed('https://bucher.example.com/'), isFalse);
      expect(idnAllowed('https://xn--0zwm56d/'), isFalse); // 通配不含根
    });
  });

  test('IP 字面量只做精确匹配', () {
    final ip = HostPolicy(
      baseUrl: Uri.parse('http://127.0.0.1:8080'),
      allowedHosts: ['[::1]'],
    );
    expect(ip.isAllowed(Uri.parse('http://127.0.0.1:9999/')), isTrue);
    expect(ip.isAllowed(Uri.parse('http://[::1]/')), isTrue);
    expect(ip.isAllowed(Uri.parse('http://127.0.0.2/')), isFalse);
  });

  test('非法主机名一律拒绝', () {
    expect(allowed('https://a..example.com/'), isFalse);
  });
}
