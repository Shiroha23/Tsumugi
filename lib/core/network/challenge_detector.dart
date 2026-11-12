import 'dart:convert';
import 'dart:typed_data';

/// 人机验证页面检测（docs/architecture.md §5.3）。
///
/// **只做检测**：命中时网络层上报 `E_CHALLENGE`，由 UI 让用户在 WebView 中手动完成，
/// 客户端不做任何自动绕过。
class ChallengeDetector {
  const ChallengeDetector({
    this.statuses = const {403, 429, 503},
    this.headerMarkers = const {'cf-mitigated': 'challenge'},
    this.bodyMarkers = const [
      'challenge-form',
      'challenge-platform',
      'cf-challenge',
      'cf-turnstile',
      'g-recaptcha',
      'h-captcha',
      '<title>just a moment',
    ],
    this.scanBytes = 64 * 1024,
  });

  /// 只有这些状态码才会进一步检查特征。
  final Set<int> statuses;

  /// 响应头（小写名）→ 值中包含的子串（忽略大小写）。
  final Map<String, String> headerMarkers;

  /// 响应体前 [scanBytes] 字节中包含的子串（忽略大小写）。
  final List<String> bodyMarkers;
  final int scanBytes;

  bool isChallenge(
    int status,
    Map<String, List<String>> headers,
    Uint8List body,
  ) {
    if (!statuses.contains(status)) return false;
    for (final MapEntry(:key, :value) in headerMarkers.entries) {
      final values = headers[key] ?? const [];
      if (values.any((v) => v.toLowerCase().contains(value))) return true;
    }
    if (bodyMarkers.isEmpty || body.isEmpty) return false;
    final head = latin1
        .decode(
          body.length > scanBytes
              ? Uint8List.sublistView(body, 0, scanBytes)
              : body,
        )
        .toLowerCase();
    return bodyMarkers.any(head.contains);
  }
}
