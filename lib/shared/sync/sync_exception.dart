/// 同步失败的类别。
enum SyncError {
  /// 未配置或配置无效（地址、目录、缺少密码）。
  invalidConfig,

  /// 连接失败、超时、证书错误。
  network,

  /// 401 / 403。
  auth,

  /// 其他非预期的服务器响应。
  server,

  /// 远端文件或本地数据超过 20 MiB。
  tooLarge,

  /// 远端文件不是本客户端能读的格式。
  badFormat,

  /// 远端文件的 `syncVersion` 高于客户端支持的版本。
  unsupportedVersion,

  /// 多次重试后仍与其他设备的写入冲突（412）。
  conflict,
}

/// 同步失败；[message] 是给用户看的中文说明。
class SyncException implements Exception {
  const SyncException(this.error, this.message);

  final SyncError error;
  final String message;

  @override
  String toString() => 'SyncException(${error.name}: $message)';
}
