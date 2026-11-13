import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../../sources/model/common.dart';
import '../../sources/source.dart';
import '../novel/novel_chapter_loader.dart';
import 'epub_writer.dart';
import 'export_models.dart';
import 'txt_writer.dart';

/// 由 sourceId 取得源实例（与阅读器共用 `SourceRuntime` 缓存的同一实例，因此共用限速队列、
/// 白名单、Cookie 与默认 headers）。每章都重新取一次：源被升级 / 禁用时拿到新状态。
typedef ExportSourceResolver = Future<Source> Function(String sourceId);

/// 经统一图片加载取得封面字节；失败时抛出（导出会改为不放封面）。
typedef ExportCoverLoader = Future<Uint8List> Function(
  String sourceId,
  String url,
  Headers? headers,
);

/// 一次导出的参数。
final class NovelExportRequest {
  const NovelExportRequest({
    required this.sourceId,
    required this.itemId,
    required this.detail,
    required this.units,
    required this.format,
    this.sourceName,
    this.language,
    this.coverHeaders,
    this.txtBom = false,
  });

  final String sourceId;
  final String itemId;

  /// 作品详情（元数据与“下一页其实是下一章”的判断）。
  final Detail detail;

  /// 要导出的章节（按顺序，见 [ExportRange.select]）。
  final List<Unit> units;
  final ExportFormat format;

  /// 源名称；为 null 时用源清单的 `name`。
  final String? sourceName;

  /// 语言标签；为 null 时用源清单的 `lang`（再缺省为 `zh`）。
  final String? language;
  final Headers? coverHeaders;

  /// TXT 是否带 UTF-8 BOM。
  final bool txtBom;
}

enum ExportPhase {
  /// 正在逐章取正文。
  fetching,

  /// 某章失败，等待用户选择重试 / 跳过 / 取消（[ExportStatus.error]）。
  paused,

  /// 正在下载封面并生成文件。
  building,
  done,
  cancelled,

  /// 生成失败或没有任何章节成功。
  failed,
}

/// 被跳过的章节及其错误。
final class ExportFailure {
  const ExportFailure(this.unit, this.error);

  final Unit unit;
  final Object error;
}

/// 导出进度快照。
final class ExportStatus {
  const ExportStatus({
    required this.phase,
    required this.completed,
    required this.total,
    this.current,
    this.error,
    this.failures = const [],
    this.file,
  });

  final ExportPhase phase;

  /// 已处理（成功或跳过）的章节数。
  final int completed;
  final int total;

  /// 正在取 / 失败的章节。
  final Unit? current;

  /// [ExportPhase.paused] 时为该章的错误；[ExportPhase.failed] 时为失败原因。
  final Object? error;
  final List<ExportFailure> failures;

  /// [ExportPhase.done] 时的结果。
  final ExportFile? file;

  bool get finished =>
      phase == ExportPhase.done ||
      phase == ExportPhase.cancelled ||
      phase == ExportPhase.failed;

  double get fraction => total == 0 ? 0 : completed / total;
}

/// 没有任何章节成功导出。
class NothingToExportException implements Exception {
  const NothingToExportException();

  @override
  String toString() => '没有成功导出的章节';
}

enum _Decision { retry, skip, skipAll, cancel }

/// `E_CHALLENGE` / `E_LOGIN_REQUIRED`：跳过也只会让后续章节同样失败，总是暂停等待用户。
bool _needsVerification(Object error) =>
    error is SourceException &&
    (error.code == SourceErrorCode.challenge ||
        error.code == SourceErrorCode.loginRequired);

/// 一次小说导出：按顺序逐章取正文（[loadNovelChapter]，与阅读器同一套分页拼接），
/// 然后生成 TXT / EPUB。
///
/// - 章节严格顺序请求（一次只有一个 `content` 调用），由源的网络层执行限速与白名单。
/// - 单章失败时进入 [ExportPhase.paused]，等待 [retry] / [skip] / [cancel]；
///   [skip] 的 `all: true` 之后的普通失败自动跳过，但需要验证 / 登录的错误仍会暂停
///   （用户可在界面上“打开验证页”完成后 [retry]）。
/// - [cancel] 立即结束（正在进行的请求结果被丢弃），[run] 返回 null。
class NovelExportJob extends ChangeNotifier {
  NovelExportJob({
    required this.request,
    required this.sourceFor,
    this.loadCover,
    DateTime Function()? clock,
    this.buildInIsolate = true,
  }) : _clock = clock ?? DateTime.now,
       _status = ExportStatus(
         phase: ExportPhase.fetching,
         completed: 0,
         total: request.units.length,
       );

  final NovelExportRequest request;
  final ExportSourceResolver sourceFor;
  final ExportCoverLoader? loadCover;
  final DateTime Function() _clock;

  /// 在后台 isolate 中压缩 / 编码，避免大部头卡住界面（测试中可关闭）。
  final bool buildInIsolate;

  ExportStatus _status;
  ExportStatus get status => _status;

  final _cancelSignal = Completer<void>();
  Completer<_Decision>? _decision;
  bool _skipAll = false;
  bool _started = false;
  bool _disposed = false;

  bool get isCancelled => _cancelSignal.isCompleted;

  /// 执行导出，返回生成的文件；取消时返回 null，生成失败时抛出（同时 [status] 为 failed）。
  /// 只能调用一次。
  Future<ExportFile?> run() async {
    if (_started) throw StateError('导出任务只能运行一次');
    _started = true;
    final chapters = <ExportedChapter>[];
    final failures = <ExportFailure>[];
    final unitIds = novelUnitIdsOf(request.detail);
    Source? lastSource;

    for (final (i, unit) in request.units.indexed) {
      _set(
        ExportStatus(
          phase: ExportPhase.fetching,
          completed: i,
          total: request.units.length,
          current: unit,
          failures: List.unmodifiable(failures),
        ),
      );
      while (true) {
        if (isCancelled) return _cancelled(i, failures);
        try {
          final source = await _orCancel(sourceFor(request.sourceId));
          if (source == null) return _cancelled(i, failures);
          lastSource = source;
          final chapter = await _orCancel(
            loadNovelChapter(
              source,
              unit.id,
              unitIds: unitIds,
              shouldStop: () => isCancelled,
            ),
          );
          if (chapter == null) return _cancelled(i, failures);
          chapters.add(
            ExportedChapter(
              unitId: unit.id,
              title: unit.title,
              content: chapter,
            ),
          );
          break;
        } on Object catch (error) {
          if (isCancelled) return _cancelled(i, failures);
          final decision = _skipAll && !_needsVerification(error)
              ? _Decision.skip
              : await _ask(unit, error, i, failures);
          switch (decision) {
            case _Decision.retry:
              _set(
                ExportStatus(
                  phase: ExportPhase.fetching,
                  completed: i,
                  total: request.units.length,
                  current: unit,
                  failures: List.unmodifiable(failures),
                ),
              );
              continue;
            case _Decision.skipAll:
              _skipAll = true;
              failures.add(ExportFailure(unit, error));
            case _Decision.skip:
              failures.add(ExportFailure(unit, error));
            case _Decision.cancel:
              return _cancelled(i, failures);
          }
          break;
        }
      }
    }

    final total = request.units.length;
    _set(
      ExportStatus(
        phase: ExportPhase.building,
        completed: total,
        total: total,
        failures: List.unmodifiable(failures),
      ),
    );
    try {
      if (chapters.isEmpty) throw const NothingToExportException();
      final manifest = lastSource?.manifest;
      final detail = request.detail;
      final cover = await _cover();
      if (isCancelled) return _cancelled(total, failures);
      final book = ExportBook(
        info: ExportBookInfo(
          sourceId: request.sourceId,
          itemId: request.itemId,
          title: detail.title,
          author: detail.author,
          description: detail.description,
          sourceName: request.sourceName ?? manifest?.name ?? request.sourceId,
          exportedAt: _clock(),
          language: request.language ?? manifest?.lang ?? 'zh',
        ),
        chapters: chapters,
        skipped: [for (final f in failures) f.unit.title],
        cover: cover,
      );
      final format = request.format;
      final bytes = buildInIsolate
          ? await _buildInIsolate(book, format, request.txtBom)
          : _build(book, format, request.txtBom);
      if (isCancelled) return _cancelled(total, failures);
      final file = ExportFile(
        fileName: '${safeFileStem(detail.title)}.${format.extension}',
        format: format,
        bytes: bytes,
      );
      _set(
        ExportStatus(
          phase: ExportPhase.done,
          completed: total,
          total: total,
          failures: List.unmodifiable(failures),
          file: file,
        ),
      );
      return file;
    } on Object catch (error) {
      _set(
        ExportStatus(
          phase: ExportPhase.failed,
          completed: total,
          total: total,
          error: error,
          failures: List.unmodifiable(failures),
        ),
      );
      rethrow;
    }
  }

  /// 重试暂停中的章节（例如在验证页完成验证后）。
  void retry() => _decide(_Decision.retry);

  /// 跳过暂停中的章节；[all] 为 true 时之后的普通失败也自动跳过。
  void skip({bool all = false}) =>
      _decide(all ? _Decision.skipAll : _Decision.skip);

  /// 取消导出。
  void cancel() {
    if (!_cancelSignal.isCompleted) _cancelSignal.complete();
    _decide(_Decision.cancel);
  }

  void _decide(_Decision d) {
    final c = _decision;
    _decision = null;
    if (c == null || c.isCompleted) return;
    // 立即离开 paused（界面按钮随即消失；导出循环在下一个微任务中继续）。
    if (d != _Decision.cancel) {
      _set(
        ExportStatus(
          phase: ExportPhase.fetching,
          completed: _status.completed,
          total: _status.total,
          current: _status.current,
          failures: _status.failures,
        ),
      );
    }
    c.complete(d);
  }

  Future<_Decision> _ask(
    Unit unit,
    Object error,
    int completed,
    List<ExportFailure> failures,
  ) {
    final c = _decision = Completer<_Decision>();
    _set(
      ExportStatus(
        phase: ExportPhase.paused,
        completed: completed,
        total: request.units.length,
        current: unit,
        error: error,
        failures: List.unmodifiable(failures),
      ),
    );
    return c.future;
  }

  /// [future] 的结果；先被取消时返回 null（[future] 之后的结果 / 错误被忽略）。
  Future<T?> _orCancel<T extends Object>(Future<T> future) {
    future.ignore();
    return Future.any<T?>([future, _cancelSignal.future.then((_) => null)]);
  }

  Future<ExportImage?> _cover() async {
    final url = request.detail.cover;
    final load = loadCover;
    if (url == null || url.isEmpty || load == null) return null;
    try {
      final bytes = await _orCancel(
        load(request.sourceId, url, request.coverHeaders),
      );
      return bytes == null ? null : ExportImage.sniff(bytes);
    } on Object {
      return null;
    }
  }

  ExportFile? _cancelled(int completed, List<ExportFailure> failures) {
    _set(
      ExportStatus(
        phase: ExportPhase.cancelled,
        completed: completed,
        total: request.units.length,
        failures: List.unmodifiable(failures),
      ),
    );
    return null;
  }

  void _set(ExportStatus s) {
    _status = s;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    cancel();
    super.dispose();
  }
}

Uint8List _build(ExportBook book, ExportFormat format, bool bom) =>
    switch (format) {
      ExportFormat.txt => buildNovelTxt(book, bom: bom),
      ExportFormat.epub => buildNovelEpub(book),
    };

/// 顶层函数：闭包只捕获参数，不会把任务对象（含 Completer 等不可发送的状态）带进 isolate。
Future<Uint8List> _buildInIsolate(
  ExportBook book,
  ExportFormat format,
  bool bom,
) => Isolate.run(() => _build(book, format, bom));
