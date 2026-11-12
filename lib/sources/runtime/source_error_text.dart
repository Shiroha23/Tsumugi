import 'dart:async';

import '../source.dart';
import 'source_runtime.dart';

/// 面向用户的错误说明（docs/source-spec.md §6 错误码 → 中文提示）。
final class SourceErrorInfo {
  const SourceErrorInfo({
    required this.title,
    this.detail,
    this.code,
    this.needsVerification = false,
  });

  /// 简短提示，例如「网络错误或超时」。
  final String title;

  /// 源 / 网络层给出的原始信息（可能为英文或技术细节）。
  final String? detail;

  final SourceErrorCode? code;

  /// `E_CHALLENGE` / `E_LOGIN_REQUIRED`：需要用户在 WebView 中手动完成验证或登录。
  final bool needsVerification;
}

SourceErrorInfo describeSourceError(Object error) => switch (error) {
  SourceException(:final code, :final message, :final status) =>
    SourceErrorInfo(
      title: switch (code) {
        SourceErrorCode.network => '网络错误或超时',
        SourceErrorCode.http =>
          status == null ? '服务器返回错误' : '服务器返回错误（HTTP $status）',
        SourceErrorCode.parse => '解析失败，源规则可能已失效',
        SourceErrorCode.challenge => '需要验证',
        SourceErrorCode.loginRequired => '需要登录',
        SourceErrorCode.hostNotAllowed => '源请求了白名单外的主机',
        SourceErrorCode.limit => '超出脚本沙箱限制',
        SourceErrorCode.unsupported => '该源不支持此功能',
      },
      detail: message,
      code: code,
      needsVerification:
          code == SourceErrorCode.challenge ||
          code == SourceErrorCode.loginRequired,
    ),
  TimeoutException() => const SourceErrorInfo(
    title: '请求超时',
    code: SourceErrorCode.network,
  ),
  SourceUnavailableException(:final reason) => SourceErrorInfo(title: reason),
  _ => SourceErrorInfo(title: '未知错误', detail: '$error'),
};
