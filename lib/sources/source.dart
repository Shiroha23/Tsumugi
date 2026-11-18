import 'model/common.dart';
import 'model/content.dart';
import 'model/manifest.dart';

/// 所有引擎（declarative / script）实现的统一源接口（docs/source-spec.md §4.1）。
abstract interface class Source {
  SourceManifest get manifest;

  Future<PageResult<SearchItem>> search(String keyword, int page);

  /// 发现页分类；不支持时抛出 [SourceErrorCode.unsupported]。
  Future<List<ExploreCategory>> explore();

  Future<PageResult<SearchItem>> exploreList(String categoryId, int page);

  Future<Detail> detail(String id);

  Future<MediaContent> content(String unitId);
}

/// docs/source-spec.md §6
enum SourceErrorCode {
  network('E_NETWORK'),
  http('E_HTTP'),
  parse('E_PARSE'),
  challenge('E_CHALLENGE'),
  loginRequired('E_LOGIN_REQUIRED'),
  hostNotAllowed('E_HOST_NOT_ALLOWED'),
  limit('E_LIMIT'),
  unsupported('E_UNSUPPORTED');

  const SourceErrorCode(this.wire);

  /// 规则 / 脚本中使用的字符串形式。
  final String wire;

  static SourceErrorCode? fromWire(String wire) =>
      values.where((c) => c.wire == wire).firstOrNull;
}

class SourceException implements Exception {
  const SourceException(this.code, [this.message, this.status]);

  final SourceErrorCode code;
  final String? message;

  /// 仅 [SourceErrorCode.http] 时有值。
  final int? status;

  @override
  String toString() =>
      'SourceException(${code.wire}${status != null ? ' $status' : ''}${message != null ? ': $message' : ''})';
}

/// 源暂时停用：脚本的 worker 曾长时间无响应（docs/architecture.md §5.5，#29）。
/// 冷却期过后、且卡住的 worker 已退出时自动恢复；用户也可以禁用该源。
///
/// 属于 [SourceErrorCode.limit]，不认识它的错误展示处按 `E_LIMIT` 显示 [message]。
class SourceSuspendedException extends SourceException {
  const SourceSuspendedException(this.sourceName, {this.processWide = false})
    : super(
        SourceErrorCode.limit,
        processWide
            ? '当前有其他源的脚本长时间无响应，暂时无法启动新的脚本，请稍后重试'
            : '该源的脚本长时间没有响应，已暂时停用，请稍后重试',
      );

  final String sourceName;

  /// 原因不在本源：全进程卡住的脚本 worker 过多（可能来自其他源）。
  final bool processWide;

  @override
  String toString() =>
      'SourceSuspendedException($sourceName${processWide ? ', process' : ''})';
}
