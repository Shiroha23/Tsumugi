import '../core/network/network_exception.dart';
import '../core/network/source_http_client.dart';
import 'model/manifest.dart';
import 'source.dart';

/// core 网络层错误 → docs/source-spec.md §6 错误码（一一映射，见 [NetworkErrorKind] 文档）。
extension NetworkExceptionMapping on NetworkException {
  SourceErrorCode get sourceErrorCode => switch (kind) {
    NetworkErrorKind.connection ||
    NetworkErrorKind.timeout ||
    NetworkErrorKind.cancelled ||
    NetworkErrorKind.tooManyRedirects ||
    NetworkErrorKind.invalidRequest => SourceErrorCode.network,
    NetworkErrorKind.http => SourceErrorCode.http,
    NetworkErrorKind.hostNotAllowed => SourceErrorCode.hostNotAllowed,
    NetworkErrorKind.challenge => SourceErrorCode.challenge,
    NetworkErrorKind.decode => SourceErrorCode.parse,
    NetworkErrorKind.responseTooLarge => SourceErrorCode.limit,
  };

  SourceException toSourceException() => SourceException(
    sourceErrorCode,
    message ?? kind.name,
    kind == NetworkErrorKind.http ? status : null,
  );
}

/// 由源清单生成网络配置（docs/source-spec.md §1：`headers` / `timeoutMs` / `rateLimit` /
/// `allowedHosts`）。不合法的 `rateLimit`（非正数）视为不限速。
SourceNetworkConfig networkConfigFromManifest(SourceManifest manifest) {
  final rate = manifest.rateLimit;
  return SourceNetworkConfig(
    sourceId: manifest.id,
    baseUrl: Uri.parse(manifest.baseUrl),
    allowedHosts: manifest.allowedHosts,
    defaultHeaders: manifest.headers,
    timeout: Duration(milliseconds: manifest.timeoutMs),
    rateLimit: rate != null && rate.requests > 0 && rate.perSeconds > 0
        ? RateLimitConfig(
            requests: rate.requests,
            per: Duration(seconds: rate.perSeconds),
          )
        : null,
  );
}
