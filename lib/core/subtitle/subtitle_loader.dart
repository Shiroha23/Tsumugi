import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../network/network_exception.dart';
import '../network/source_http_client.dart';
import 'subtitle_parser.dart';

/// 经源的网络层取回外挂字幕并解析（architecture §6.4.7）。
///
/// 请求走 [client]（该源的白名单含每跳重定向、Cookie、默认 headers、限速；`source` 通道）。
/// 非 2xx 抛 [NetworkException]（[NetworkErrorKind.http]）；超过 [maxBytes]（`Content-Length`
/// 或实际读取）、编码 / 格式不可用时抛 [SubtitleFormatException]。
///
/// 整个请求（含限速排队、等待响应头与读取响应体）不超过 [totalTimeout]，超时抛
/// [NetworkErrorKind.timeout]；[cancellation] 取消时抛 [NetworkErrorKind.cancelled]。两者都中止请求。
/// （`openStream` 自身的超时只限制相邻两块数据的间隔，慢速上游可以一直拖着。）
Future<SubtitleDocument> fetchSubtitle(
  SourceHttpClient client,
  String url, {
  String? format,
  String? charset,
  int maxBytes = maxSubtitleBytes,
  Duration totalTimeout = defaultSubtitleTimeout,
  NetCancellation? cancellation,
  void Function(String message)? log,
}) async {
  final declared = SubtitleFormat.parse(format);
  if (!SubtitleFormat.isBlank(format) && declared == null) {
    throw SubtitleFormatException('不支持的字幕格式：$format');
  }
  final abort = NetCancellation();
  var timedOut = false;
  cancellation?.whenCancelled.then((_) => abort.cancel());
  final timer = Timer(totalTimeout, () {
    timedOut = true;
    abort.cancel();
  });
  NetworkException aborted() => timedOut
      ? NetworkException(
          NetworkErrorKind.timeout,
          message: 'subtitle not loaded within ${totalTimeout.inSeconds} s',
          uri: Uri.tryParse(url),
        )
      : NetworkException(NetworkErrorKind.cancelled, uri: Uri.tryParse(url));
  try {
    final NetStreamResponse response;
    try {
      response = await client.openStream(NetRequest(url, cancellation: abort));
    } on NetworkException catch (e) {
      if (abort.isCancelled && e.kind == NetworkErrorKind.cancelled) {
        throw aborted();
      }
      rethrow;
    }
    if (abort.isCancelled) {
      response.cancel();
      throw aborted();
    }
    if (!response.ok) {
      response.cancel();
      throw NetworkException(
        NetworkErrorKind.http,
        message: 'HTTP ${response.status}',
        uri: response.url,
        status: response.status,
      );
    }
    final length = int.tryParse(response.headers['content-length'] ?? '');
    if (length != null && length > maxBytes) {
      response.cancel();
      throw SubtitleFormatException(_tooLarge(maxBytes));
    }
    final bytes = BytesBuilder(copy: false);
    final done = Completer<void>();
    late final StreamSubscription<List<int>> sub;
    void stop(Object error) {
      sub.cancel().ignore();
      response.cancel();
      if (!done.isCompleted) done.completeError(error);
    }

    sub = response.body.listen(
      (chunk) {
        if (bytes.length + chunk.length > maxBytes) {
          stop(SubtitleFormatException(_tooLarge(maxBytes)));
          return;
        }
        bytes.add(chunk);
      },
      onError: (Object e, StackTrace st) {
        if (done.isCompleted) return;
        if (abort.isCancelled) {
          done.completeError(aborted());
        } else {
          done.completeError(e, st);
        }
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: true,
    );
    abort.whenCancelled.then((_) {
      if (!done.isCompleted) stop(aborted());
    });
    await done.future;
    timer.cancel();
    return await _decodeAndParse(
      bytes.takeBytes(),
      charset: charset,
      contentType: response.headers['content-type'],
      declared: declared,
      log: log,
    );
  } finally {
    timer.cancel();
  }
}

/// 取一条字幕的总时限。
const defaultSubtitleTimeout = Duration(seconds: 30);

/// 大文件在后台 isolate 中解码与解析，不卡界面（日志回调不跨 isolate）。
/// 单独成函数：交给 [Isolate.run] 的闭包只能捕获可发送的值（不能带上响应、订阅等）。
Future<SubtitleDocument> _decodeAndParse(
  Uint8List data, {
  String? charset,
  String? contentType,
  SubtitleFormat? declared,
  void Function(String message)? log,
}) async {
  if (data.length > isolateThreshold) {
    return Isolate.run(
      () => parseSubtitle(
        decodeSubtitle(data, charset: charset, contentType: contentType),
        declared: declared,
      ),
    );
  }
  return parseSubtitle(
    decodeSubtitle(data, charset: charset, contentType: contentType, log: log),
    declared: declared,
  );
}

/// 超过这个大小的字幕在后台 isolate 中解析。
const isolateThreshold = 256 * 1024;

String _tooLarge(int maxBytes) => maxBytes >= 1024 * 1024
    ? '字幕文件超过 ${maxBytes ~/ (1024 * 1024)} MB'
    : '字幕文件超过 ${maxBytes ~/ 1024} KB';
