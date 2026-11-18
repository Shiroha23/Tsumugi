import 'dart:async';

import '../source.dart';
import '../source_call.dart';
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
  // 先于 SourceException：它是 E_LIMIT 的子类型。
  SourceSuspendedException(:final sourceName, :final processWide) =>
    SourceErrorInfo(
      title: processWide ? '暂时无法启动脚本源' : '「$sourceName」暂时不可用',
      detail: processWide
          ? '其他源的脚本长时间没有响应，暂时不能启动新的脚本。请稍后重试'
          : '该源的脚本长时间没有响应，已暂时停用。请稍后重试；若反复出现，建议禁用或删除该源',
      code: SourceErrorCode.limit,
    ),
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
  SourceCallTimeoutException(awaitedUser: true) => const SourceErrorInfo(
    title: '验证后仍然超时',
    detail: '本次请求中打开过验证页，之后源仍未及时返回；若仍需验证，可再次打开验证页后重试',
    code: SourceErrorCode.challenge,
    needsVerification: true,
  ),
  SourceCallTimeoutException() => const SourceErrorInfo(
    title: '请求超时',
    detail: '源长时间没有返回结果，已取消本次请求，可稍后重试',
    code: SourceErrorCode.network,
  ),
  SourceCallCancelledException() => const SourceErrorInfo(title: '请求已取消'),
  TimeoutException() => const SourceErrorInfo(
    title: '请求超时',
    code: SourceErrorCode.network,
  ),
  SourceUnavailableException(:final reason) => SourceErrorInfo(title: reason),
  _ => SourceErrorInfo(title: '未知错误', detail: '$error'),
};
