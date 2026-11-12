import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/sources/registry/version.dart';

void main() {
  int sign(String a, String b) => compareVersions(a, b).sign;

  test('按数值逐段比较', () {
    expect(sign('1.0.0', '1.0.0'), 0);
    expect(sign('1.0.1', '1.0.0'), 1);
    expect(sign('1.2.0', '1.10.0'), -1);
    expect(sign('2.0.0', '1.99.99'), 1);
  });

  test('缺失段视为 0，忽略 v 前缀与构建元数据', () {
    expect(sign('1.0', '1.0.0'), 0);
    expect(sign('v1.2.3', '1.2.3'), 0);
    expect(sign('1.2.3+build.5', '1.2.3'), 0);
    expect(sign('1.1', '1.0.9'), 1);
  });

  test('预发布版低于正式版', () {
    expect(sign('1.0.0-beta.1', '1.0.0'), -1);
    expect(sign('1.0.0', '1.0.0-rc.1'), 1);
    expect(sign('1.0.0-alpha', '1.0.0-beta'), -1);
    expect(sign('1.0.0-beta.2', '1.0.0-beta.10'), -1);
    expect(sign('1.0.0-1', '1.0.0-alpha'), -1);
    expect(sign('1.0.0-beta', '1.0.0-beta.0'), -1);
    expect(sign('1.0.0-beta.0', '1.0.0-beta'), 1);
    expect(sign('1.0.0-alpha.1', '1.0.0-alpha.beta'), -1);
  });
}
