/// HLS 字幕轨（WebVTT）的取回与解析（architecture §6.4.7「HLS 字幕轨」，#84）。
///
/// 字幕轨不交给播放器：本地媒体代理改写主播放列表时登记它（`MediaProxySession.subtitleTracks`），
/// 这里经**回环地址**请求同一会话的代理地址取字幕播放列表与分片，因此主机白名单（含每一跳重定向）、
/// Cookie、限速、播放列表大小上限、`prepareTimeout` 与 WebVTT 文件头识别都与播放器的请求相同；
/// 本地来源会话（离线回放）同样适用。只请求与字幕播放列表同一会话（同一端口、同一令牌）的回环地址。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../network/media/hls_playlist.dart' show looksLikeHlsPlaylist;
import '../network/network_exception.dart';
import '../network/source_http_client.dart' show NetCancellation;
import 'subtitle_loader.dart' show isolateThreshold;
import 'subtitle_parser.dart';

/// 字幕播放列表的大小上限（与代理的播放列表上限相同）。
const maxHlsSubtitlePlaylistBytes = 4 * 1024 * 1024;

/// 一条字幕轨最多的分片数（地址相同的只算一次）。
const maxHlsSubtitleSegments = 10000;

/// 单个分片的大小上限。
const maxHlsSubtitleSegmentBytes = 1024 * 1024;

/// 一条字幕轨所有分片合计的大小上限；超过时停止再取，已取到的照常显示。
const maxHlsSubtitleTotalBytes = 8 * 1024 * 1024;

/// 每个请求（字幕播放列表或分片）的总时限。
const hlsSubtitleRequestTimeout = Duration(seconds: 30);

/// 字幕播放列表中的一个分片：[start] 为它在播放列表时间轴上的开始时间（前面分片 `EXTINF` 之和）。
class HlsSubtitleSegment {
  const HlsSubtitleSegment(this.url, this.start);

  final Uri url;
  final Duration start;

  @override
  bool operator ==(Object other) =>
      other is HlsSubtitleSegment && other.url == url && other.start == start;

  @override
  int get hashCode => Object.hash(url, start);

  @override
  String toString() => 'HlsSubtitleSegment($url, $start)';
}

/// 解析（代理改写过的）字幕子播放列表：每个 URI 行一个分片，地址基于 [base] 解析；
/// 地址相同的（`EXT-X-BYTERANGE` 引用同一文件的不同区间）只保留第一个——整个文件取一次即可。
/// 不是播放列表、或分片超过 [maxSegments] 个时抛 [SubtitleFormatException]。
List<HlsSubtitleSegment> parseHlsSubtitlePlaylist(
  String text,
  Uri base, {
  int maxSegments = maxHlsSubtitleSegments,
}) {
  final lines = const LineSplitter().convert(
    text.startsWith(String.fromCharCode(0xFEFF)) ? text.substring(1) : text,
  );
  final first = lines.indexWhere((l) => l.trim().isNotEmpty);
  if (first < 0 || lines[first].trim() != '#EXTM3U') {
    throw const SubtitleFormatException('字幕播放列表无效');
  }
  final out = <HlsSubtitleSegment>[];
  final seen = <Uri>{};
  var at = Duration.zero;
  Duration? pending;
  for (final raw in lines.skip(first + 1)) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('#')) {
      if (line.startsWith('#EXTINF:')) {
        final value = line.substring(8).split(',').first.trim();
        final seconds = double.tryParse(value);
        pending = seconds == null || !seconds.isFinite || seconds < 0
            ? Duration.zero
            : Duration(microseconds: (seconds * 1e6).round());
      }
      continue;
    }
    final Uri url;
    try {
      url = base.resolve(line);
    } on FormatException {
      pending = null;
      continue;
    }
    if (seen.add(url)) {
      if (out.length >= maxSegments) {
        throw SubtitleFormatException('字幕分片超过 $maxSegments 个');
      }
      out.add(HlsSubtitleSegment(url, at));
    }
    at += pending ?? Duration.zero;
    pending = null;
  }
  return out;
}

/// 分片内的 cue 时间 [cue] → 播放位置（mpv 的 `time-pos`）。
///
/// RFC 8216 §3.5：MPEG-TS 时间 = cue − `LOCAL` + `MPEGTS` / 90000（没有 [map] 时 `LOCAL` 与 `MPEGTS` 都按 0）。
/// mpv 的位置 = PTS − [presentationStart]（`demuxer-start-time`）。33 位时间戳回绕：差值按 2³³ / 90 kHz
/// 的周期折回到离 0 最近的值。
Duration hlsCueTime(
  Duration cue,
  WebVttTimestampMap? map,
  Duration presentationStart,
) {
  // 以 90 kHz 计算：cue 精确到毫秒（1 ms = 90），开始时间按微秒换算后取整。
  final localMs = map?.local.inMilliseconds ?? 0;
  final mpegts = map?.mpegts ?? 0;
  final startTicks = (presentationStart.inMicroseconds * 9 / 100).round();
  var t = (cue.inMilliseconds - localMs) * 90 + mpegts - startTicks;
  t %= mpegTsWrap; // Dart 的 % 结果非负
  if (t >= mpegTsWrap ~/ 2) t -= mpegTsWrap;
  return Duration(microseconds: (t * 100 / 9).round());
}

/// 取回并解析一条 HLS 字幕轨，返回换算到播放位置的时间轴（architecture §6.4.7）。
///
/// [playlist] 为会话登记的字幕播放列表代理地址（必须是回环地址）。分片从 [position] 所在的那个开始向后取，
/// 再取前面的；最多 [concurrency] 个同时请求。每取完一批（间隔不少于 [progressInterval]）调用一次 [onProgress]。
///
/// 限制：字幕播放列表 [maxHlsSubtitlePlaylistBytes]；分片 [maxSegmentBytes]（超过时跳过该分片）；合计
/// [maxTotalBytes]（按实际读到的字节计，含失败分片已读的部分与并发中的读取）与 [maxSubtitleCues] 条
/// （达到时停止再取）；每个请求 [requestTimeout]（超时即断开连接）。错误与日志中的地址不含会话令牌。
/// 字幕播放列表取不到或无效时抛 [NetworkException] / [SubtitleFormatException]；单个分片失败时跳过，
/// 全部失败时抛第一个错误。[cancellation] 取消时中止全部请求并抛 [NetworkErrorKind.cancelled]。
Future<SubtitleDocument> loadHlsSubtitles(
  Uri playlist, {
  required Duration presentationStart,
  Duration position = Duration.zero,
  NetCancellation? cancellation,
  void Function(SubtitleDocument document)? onProgress,
  int maxSegments = maxHlsSubtitleSegments,
  int maxSegmentBytes = maxHlsSubtitleSegmentBytes,
  int maxTotalBytes = maxHlsSubtitleTotalBytes,
  Duration requestTimeout = hlsSubtitleRequestTimeout,
  int concurrency = 4,
  Duration progressInterval = const Duration(milliseconds: 300),
  void Function(String message)? log,
}) async {
  if (!_isLoopback(playlist) || playlist.pathSegments.length != 3) {
    throw ArgumentError.value(playlist, 'playlist', '不是本地媒体代理的地址');
  }
  final client = HttpClient()
    ..findProxy = ((_) => 'DIRECT')
    ..autoUncompress = false
    ..connectionTimeout = requestTimeout;
  var cancelled = false;
  cancellation?.whenCancelled.then((_) {
    cancelled = true;
    client.close(force: true);
  });
  NetworkException cancelledError() =>
      NetworkException(NetworkErrorKind.cancelled, uri: _redact(playlist));
  try {
    final (playlistBytes, _) = await _get(
      client,
      playlist,
      maxHlsSubtitlePlaylistBytes,
      requestTimeout,
    );
    if (cancelled) throw cancelledError();
    if (!looksLikeHlsPlaylist(playlistBytes)) {
      throw const SubtitleFormatException('字幕播放列表无效');
    }
    final segments = parseHlsSubtitlePlaylist(
      utf8.decode(playlistBytes, allowMalformed: true),
      playlist,
      maxSegments: maxSegments,
    );
    final order = hlsSubtitleFetchOrder(segments, position);

    final cues = <SubtitleCue>{};
    final budget = _Budget(maxTotalBytes);
    var next = 0;
    var succeeded = 0;
    var stopped = false;
    Object? firstError;
    StackTrace? firstStack;
    var lastEmit = DateTime.now();

    SubtitleDocument build() {
      final list = [
        for (final c in cues)
          if (c.end > Duration.zero) c,
      ];
      // 稳定排序：同一开始时间保持取得的顺序。
      final indexed = list.indexed.toList()
        ..sort((a, b) {
          final c = a.$2.start.compareTo(b.$2.start);
          return c != 0 ? c : a.$1.compareTo(b.$1);
        });
      return SubtitleDocument(SubtitleFormat.vtt, [
        for (final (_, c) in indexed) c,
      ]);
    }

    Future<void> worker() async {
      while (!stopped && !cancelled && next < order.length) {
        if (budget.exhausted) {
          log?.call('HLS subtitles: total size limit reached');
          stopped = true;
          return;
        }
        final segment = segments[order[next++]];
        if (!_sameSession(segment.url, playlist)) {
          // 代理给不出地址的分片（白名单外、数量超限等）：改写后的地址不在本会话，跳过。
          firstError ??= SubtitleFormatException('字幕分片地址无效');
          continue;
        }
        try {
          final (bytes, contentType) = await _get(
            client,
            segment.url,
            maxSegmentBytes,
            requestTimeout,
            budget: budget,
          );
          if (cancelled || stopped) return;
          final parsed = await _parseSegment(bytes, contentType);
          if (cancelled || stopped) return;
          succeeded++;
          final map = parsed.timestampMap;
          for (final c in parsed.cues) {
            if (cues.length >= maxSubtitleCues) {
              stopped = true;
              break;
            }
            cues.add(
              SubtitleCue(
                hlsCueTime(c.start, map, presentationStart),
                hlsCueTime(c.end, map, presentationStart),
                c.text,
              ),
            );
          }
          final now = DateTime.now();
          if (onProgress != null &&
              now.difference(lastEmit) >= progressInterval) {
            lastEmit = now;
            onProgress(build());
          }
        } on _BudgetExhausted {
          log?.call('HLS subtitles: total size limit reached');
          stopped = true;
          firstError ??= SubtitleFormatException(_trackTooLarge(maxTotalBytes));
          return;
        } on Object catch (e, st) {
          if (cancelled) return;
          log?.call('HLS subtitle segment failed: $e');
          if (firstError == null) {
            firstError = e;
            firstStack = st;
          }
        }
      }
    }

    await Future.wait([
      for (var i = 0; i < concurrency.clamp(1, 16); i++) worker(),
    ]);
    if (cancelled) throw cancelledError();
    if (succeeded == 0 && firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStack ?? StackTrace.current);
    }
    return build();
  } on Object {
    if (cancelled) throw cancelledError();
    rethrow;
  } finally {
    client.close(force: true);
  }
}

/// 取分片的顺序（下标）：从 [position] 所在的分片（开始时间不晚于它的最后一个）向后，再从它之前的向前。
List<int> hlsSubtitleFetchOrder(
  List<HlsSubtitleSegment> segments,
  Duration position,
) {
  var at = 0;
  for (var i = 0; i < segments.length; i++) {
    if (segments[i].start <= position) at = i;
  }
  return [
    for (var i = at; i < segments.length; i++) i,
    for (var i = at - 1; i >= 0; i--) i,
  ];
}

Future<WebVttSegment> _parseSegment(Uint8List bytes, String? contentType) {
  WebVttSegment parse() =>
      parseWebVttSegment(decodeSubtitle(bytes, contentType: contentType));
  return bytes.length > isolateThreshold
      ? Isolate.run(parse)
      : Future.sync(parse);
}

bool _isLoopback(Uri url) =>
    url.scheme == 'http' &&
    !url.hasQuery &&
    (InternetAddress.tryParse(url.host)?.isLoopback ?? false);

/// [url] 与字幕播放列表 [playlist] 属于同一会话：同一回环地址与端口、同一令牌，路径为 `<令牌>/<编号>/<文件名>`。
bool _sameSession(Uri url, Uri playlist) =>
    _isLoopback(url) &&
    url.host == playlist.host &&
    url.port == playlist.port &&
    url.pathSegments.length == 3 &&
    url.pathSegments.first == playlist.pathSegments.first;

/// 一条字幕轨共用的字节预算：按读到的每一块扣减。
class _Budget {
  _Budget(this.remaining);

  int remaining;

  bool get exhausted => remaining <= 0;
}

class _BudgetExhausted implements Exception {}

/// 去掉代理地址中的会话令牌（错误与日志用）：`/<令牌>/<编号>/<文件名>` → `/-/<编号>/<文件名>`。
Uri _redact(Uri url) => url.pathSegments.length == 3
    ? url.replace(pathSegments: ['-', ...url.pathSegments.skip(1)])
    : url.replace(path: '/-');

/// GET [url]（不跟随重定向）：非 200 抛 [NetworkErrorKind.http]；超过 [maxBytes]（`Content-Length` 或实际读取）
/// 抛 [SubtitleFormatException]；[budget] 不够时抛 [_BudgetExhausted]；整个请求超过 [timeout] 抛
/// [NetworkErrorKind.timeout]。任何一种失败都立即取消响应体的读取（dart:io 随之关闭该连接），不在后台继续读。
Future<(Uint8List, String?)> _get(
  HttpClient client,
  Uri url,
  int maxBytes,
  Duration timeout, {
  _Budget? budget,
}) async {
  final shown = _redact(url);
  final result = Completer<(Uint8List, String?)>();
  HttpClientRequest? request;
  StreamSubscription<List<int>>? body;
  void finish(Object error) {
    if (result.isCompleted) return;
    result.completeError(error);
    body?.cancel().ignore();
    request?.abort();
  }

  NetworkException connectionError(Object e) => NetworkException(
    NetworkErrorKind.connection,
    message: e is SocketException ? 'socket error' : e.runtimeType.toString(),
    uri: shown,
  );

  final timer = Timer(
    timeout,
    () => finish(
      NetworkException(
        NetworkErrorKind.timeout,
        message: 'not loaded within ${timeout.inSeconds} s',
        uri: shown,
      ),
    ),
  );
  () async {
    try {
      final req = request = await client.getUrl(url);
      if (result.isCompleted) return req.abort();
      req.followRedirects = false;
      final res = await req.close();
      if (result.isCompleted) {
        res.listen(null).cancel().ignore();
        return;
      }
      if (res.statusCode != HttpStatus.ok) {
        res.listen(null).cancel().ignore();
        return finish(
          NetworkException(
            NetworkErrorKind.http,
            message: 'HTTP ${res.statusCode}',
            uri: shown,
            status: res.statusCode,
          ),
        );
      }
      if (res.contentLength > maxBytes) {
        res.listen(null).cancel().ignore();
        return finish(SubtitleFormatException(_tooLarge(maxBytes)));
      }
      final type = res.headers.value(HttpHeaders.contentTypeHeader);
      final out = BytesBuilder(copy: false);
      body = res.listen(
        (chunk) {
          if (result.isCompleted) return;
          if (out.length + chunk.length > maxBytes) {
            return finish(SubtitleFormatException(_tooLarge(maxBytes)));
          }
          if (budget != null) {
            if (chunk.length > budget.remaining) {
              budget.remaining = 0;
              return finish(_BudgetExhausted());
            }
            budget.remaining -= chunk.length;
          }
          out.add(chunk);
        },
        onError: (Object e) => finish(connectionError(e)),
        onDone: () {
          if (!result.isCompleted) result.complete((out.takeBytes(), type));
        },
        cancelOnError: true,
      );
    } on Object catch (e) {
      finish(connectionError(e));
    }
  }();
  try {
    return await result.future;
  } finally {
    timer.cancel();
  }
}

String _trackTooLarge(int maxBytes) => '字幕轨超过 ${maxBytes ~/ (1024 * 1024)} MB';

String _tooLarge(int maxBytes) => maxBytes >= 1024 * 1024
    ? '字幕分片超过 ${maxBytes ~/ (1024 * 1024)} MB'
    : '字幕分片超过 ${maxBytes ~/ 1024} KB';
