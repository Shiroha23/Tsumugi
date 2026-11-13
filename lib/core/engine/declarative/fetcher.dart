/// 声明式引擎访问网络的唯一入口。
///
/// 引擎本身不实现网络：真实实现由 `lib/core/network/`（按源的 Cookie、限速、
/// 默认 headers、白名单、挑战检测）适配此接口；测试用内存假实现。
library;

/// 一次 HTTP 请求。[url] 已是绝对地址，[headers] 已合并源的默认 headers。
class FetchRequest {
  const FetchRequest({
    required this.url,
    this.method = 'GET',
    this.headers = const {},
    this.body,
    this.charset,
  });

  final Uri url;

  /// `GET` 或 `POST`。
  final String method;
  final Map<String, String> headers;
  final String? body;

  /// 强制按此字符集（WHATWG 标签）解码响应；null 时由网络层自动识别。
  final String? charset;

  @override
  String toString() => '$method $url';
}

/// HTTP 响应，[body] 为解码后的文本。
class FetchResponse {
  const FetchResponse({
    required this.status,
    required this.url,
    required this.body,
    this.headers = const {},
  });

  final int status;

  /// 跟随重定向后的最终地址。
  final Uri url;
  final Map<String, String> headers;
  final String body;
}

/// 网络层报告的失败。[code] 取自 source-spec §6（如 `E_NETWORK`、`E_CHALLENGE`）。
class FetchException implements Exception {
  const FetchException(this.code, [this.message, this.status]);

  final String code;
  final String? message;
  final int? status;

  @override
  String toString() =>
      'FetchException($code${status != null ? ' $status' : ''}'
      '${message != null ? ': $message' : ''})';
}

/// 网络抽象。实现方应在失败时抛出 [FetchException]；非 2xx 响应可以直接返回，
/// 由引擎转换为 `E_HTTP`。
abstract interface class Fetcher {
  Future<FetchResponse> fetch(FetchRequest request);
}
