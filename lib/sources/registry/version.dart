/// 比较两个语义化版本号（docs/source-spec.md §1 `version`）。
///
/// 返回负数 / 0 / 正数，分别表示 a < b、a == b、a > b。
/// 实现上较宽松：主版本段按 `.` 切分逐段比较，数字段按数值、非数字段按字典序，缺失段视为 0；
/// 带预发布标签（`-beta.1`）的版本低于同号正式版，预发布段按 semver 比较（不补 0）；
/// 构建元数据（`+...`）忽略。
int compareVersions(String a, String b) {
  final (aCore, aPre) = _split(a);
  final (bCore, bPre) = _split(b);
  final core = _compareSegments(aCore, bCore);
  if (core != 0) return core;
  if (aPre == null && bPre == null) return 0;
  if (aPre == null) return 1;
  if (bPre == null) return -1;
  return _compareSegments(aPre, bPre, pad: false);
}

(List<String>, List<String>?) _split(String v) {
  var s = v.trim();
  if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
  final plus = s.indexOf('+');
  if (plus >= 0) s = s.substring(0, plus);
  final dash = s.indexOf('-');
  final core = dash >= 0 ? s.substring(0, dash) : s;
  final pre = dash >= 0 ? s.substring(dash + 1) : null;
  return (core.split('.'), pre?.split('.'));
}

/// [pad] 为 true 时缺失段视为 0（用于主版本段）；为 false 时按 semver 预发布规则，
/// 共同段都相同则段数少的更低（`1.0.0-beta` < `1.0.0-beta.0`）。
int _compareSegments(List<String> a, List<String> b, {bool pad = true}) {
  final n = pad
      ? (a.length > b.length ? a.length : b.length)
      : (a.length < b.length ? a.length : b.length);
  for (var i = 0; i < n; i++) {
    final x = i < a.length ? a[i] : '0';
    final y = i < b.length ? b[i] : '0';
    final xi = int.tryParse(x);
    final yi = int.tryParse(y);
    final int c;
    if (xi != null && yi != null) {
      c = xi.compareTo(yi);
    } else if (xi != null) {
      c = -1; // semver：数字标识符低于字母标识符
    } else if (yi != null) {
      c = 1;
    } else {
      c = x.compareTo(y);
    }
    if (c != 0) return c;
  }
  return pad ? 0 : a.length.compareTo(b.length);
}
