/// 网络层错误类别。
///
/// core 层不依赖 `lib/sources/`，因此这里定义自己的错误类型；
/// `lib/sources/network_error_mapping.dart` 负责一一映射到 docs/source-spec.md §6 的错误码：
///
/// | [NetworkErrorKind]  | source-spec §6        |
/// |---------------------|-----------------------|
/// | [connection]        | `E_NETWORK`           |
/// | [timeout]           | `E_NETWORK`           |
/// | [cancelled]         | `E_NETWORK`           |
/// | [tooManyRedirects]  | `E_NETWORK`           |
/// | [invalidRequest]    | `E_NETWORK`           |
/// | [http]              | `E_HTTP`（附 status） |
/// | [hostNotAllowed]    | `E_HOST_NOT_ALLOWED`  |
/// | [challenge]         | `E_CHALLENGE`         |
/// | [decode]            | `E_PARSE`             |
/// | [responseTooLarge]  | `E_LIMIT`             |
enum NetworkErrorKind {
  /// 连接失败、连接被重置、DNS 失败、TLS 错误等。
  connection,

  /// 单次请求超过 `timeout`。
  timeout,

  /// 调用方通过 [NetCancellation] 取消。
  cancelled,

  /// 重定向次数超过上限。
  tooManyRedirects,

  /// 请求本身不合法（不支持的 method、无法解析的 URL 等）。
  invalidRequest,

  /// 非 2xx 响应（仅在调用方要求 `throwOnHttpError` 时抛出）。
  http,

  /// 请求（或重定向）目标不在源的白名单中。
  hostNotAllowed,

  /// 检测到人机验证页面，需要用户在 WebView 中手动完成。
  challenge,

  /// 响应体无法按要求解码（如 JSON 解析失败）。
  decode,

  /// 响应体超过 `maxResponseBytes`。
  responseTooLarge,
}

class NetworkException implements Exception {
  const NetworkException(
    this.kind, {
    this.message,
    this.uri,
    this.status,
    this.cause,
  });

  final NetworkErrorKind kind;
  final String? message;

  /// 出错的地址。对于 [NetworkErrorKind.challenge]，即需要在 WebView 中打开的页面。
  final Uri? uri;

  /// HTTP 状态码（[NetworkErrorKind.http] / [NetworkErrorKind.challenge] 时有值）。
  final int? status;

  /// 底层异常，仅用于调试日志。
  final Object? cause;

  @override
  String toString() {
    final parts = [
      kind.name,
      if (status != null) '$status',
      if (uri != null) '$uri',
      ?message,
    ];
    return 'NetworkException(${parts.join(' ')})';
  }
}
