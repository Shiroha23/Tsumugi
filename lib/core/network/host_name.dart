/// 主机名规范化，供 [HostPolicy] 在白名单与请求两侧使用同一种表示。
///
/// 规则：
/// 1. 百分号解码（Dart 的 [Uri] 会把非 ASCII 主机编码成 `%C3%BC` 形式）并转小写；
/// 2. IPv6 字面量（含 `:`）去掉方括号后原样返回；
/// 3. 去掉一个结尾的 `.`（DNS 根），空标签视为非法；
/// 4. 含非 ASCII 字符的标签转为 Punycode（`xn--…`，RFC 3492）。
///
/// 只做 IDNA 的核心部分：不做 UTS #46 映射（如全角字符、`ß`），
/// 这类写法会被规范成另一个主机名，从而被拒绝（安全方向的失败）。
library;

/// 返回规范化后的主机名；无法解析时返回 `null`。
String? normalizeHost(String raw) {
  var host = raw;
  // 只有 [Uri] 产出的主机才是百分号编码的；配置里的 Unicode 原文不能再解码。
  if (host.contains('%')) {
    try {
      host = Uri.decodeComponent(host);
    } on ArgumentError {
      return null;
    }
  }
  host = host.toLowerCase();
  if (host.startsWith('[') && host.endsWith(']')) {
    host = host.substring(1, host.length - 1);
  }
  if (host.contains(':')) return host.isEmpty ? null : host; // IPv6
  if (host.endsWith('.')) host = host.substring(0, host.length - 1);
  if (host.isEmpty) return null;

  final labels = host.split('.');
  final out = <String>[];
  for (final label in labels) {
    if (label.isEmpty) return null;
    out.add(_isAscii(label) ? label : 'xn--${punycodeEncode(label)}');
  }
  return out.join('.');
}

bool _isAscii(String s) => s.codeUnits.every((c) => c < 0x80);

// --- RFC 3492 Punycode ---------------------------------------------------------

const _base = 36;
const _tMin = 1;
const _tMax = 26;
const _skew = 38;
const _damp = 700;
const _initialBias = 72;
const _initialN = 0x80;

/// 把一个标签编码为 Punycode（不含 `xn--` 前缀）。
String punycodeEncode(String input) {
  final codePoints = input.runes.toList();
  final out = StringBuffer();
  for (final c in codePoints) {
    if (c < 0x80) out.writeCharCode(c);
  }
  final basicCount = out.length;
  var handled = basicCount;
  if (basicCount > 0) out.write('-');

  var n = _initialN;
  var delta = 0;
  var bias = _initialBias;

  while (handled < codePoints.length) {
    var m = 0x10FFFF + 1;
    for (final c in codePoints) {
      if (c >= n && c < m) m = c;
    }
    delta += (m - n) * (handled + 1);
    n = m;
    for (final c in codePoints) {
      if (c < n) delta++;
      if (c == n) {
        var q = delta;
        for (var k = _base; ; k += _base) {
          final t = k <= bias ? _tMin : (k >= bias + _tMax ? _tMax : k - bias);
          if (q < t) break;
          out.writeCharCode(_digit(t + (q - t) % (_base - t)));
          q = (q - t) ~/ (_base - t);
        }
        out.writeCharCode(_digit(q));
        bias = _adapt(delta, handled + 1, handled == basicCount);
        delta = 0;
        handled++;
      }
    }
    delta++;
    n++;
  }
  return out.toString();
}

/// 0–25 → a–z，26–35 → 0–9。
int _digit(int d) => d < 26 ? 0x61 + d : 0x16 + d;

int _adapt(int delta, int numPoints, bool firstTime) {
  var d = firstTime ? delta ~/ _damp : delta ~/ 2;
  d += d ~/ numPoints;
  var k = 0;
  while (d > ((_base - _tMin) * _tMax) ~/ 2) {
    d ~/= _base - _tMin;
    k += _base;
  }
  return k + ((_base - _tMin + 1) * d) ~/ (d + _skew);
}
