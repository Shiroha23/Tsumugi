/// 仓库操作失败的原因；`name` 作为错误码存入 `source_repositories.last_error_code`。
enum RepositoryErrorKind {
  /// 连接失败、超时、读取中断。
  network,

  /// 非 2xx 响应或无效的重定向。
  http,

  /// 地址（含重定向的某一跳）不是 https，且不是回环地址。
  insecureUrl,

  /// 重定向次数超限。
  tooManyRedirects,

  /// 索引或清单超过大小上限。
  tooLarge,

  /// 索引不是合法的 JSON 或不符合 source-spec §7。
  invalidIndex,

  /// 索引的 `repoVersion` 高于客户端支持的版本。
  unsupportedRepoVersion,

  /// 条目的 `apiVersion` 不被客户端支持。
  unsupportedApiVersion,

  /// 清单原始字节的 sha256 与索引不符。
  hashMismatch,

  /// 清单的 id / version / apiVersion 与索引条目不一致。
  manifestMismatch,

  /// 同 id 的源来自本地导入或其他仓库，本仓库不能安装 / 更新它。
  otherOrigin,

  /// 已订阅该仓库。
  alreadySubscribed,
}

class RepositoryException implements Exception {
  RepositoryException(this.kind, this.message, {this.status});

  final RepositoryErrorKind kind;

  /// 面向用户的说明（中文）。
  final String message;

  /// HTTP 状态码（[RepositoryErrorKind.http] 时可能有）。
  final int? status;

  @override
  String toString() => 'RepositoryException(${kind.name}: $message)';
}
