import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import '../network_exception.dart';
import '../pausable_deadline.dart';
import '../source_http_client.dart';
import 'connection_watch.dart';
import 'hls_playlist.dart';
import 'media_signature.dart';

/// 本地媒体代理：播放器只访问 `http://127.0.0.1:<port>/<token>/…`，代理再经该源的
/// [SourceHttpClient] 取上游内容（architecture §6.4）。因此音视频的每个请求——包括 HLS 的
/// 子播放列表、分片与密钥——都：
///
/// - 只能发往该源 `HostPolicy` 白名单内的主机（每一跳重定向同样检查）；
/// - 带上该源的 Cookie、默认 headers、会话 UA 以及 `StreamRef.headers`；
/// - 计入该客户端的限速。
///
/// 播放器拿不到任何上游地址：HLS 播放列表中的地址全部改写为代理地址，每个地址对应会话内的
/// 一个编号，播放器只能请求代理见过的地址。交给播放器的内容只有三类：改写过的 HLS 播放列表、
/// 文件头可识别的媒体容器（[looksLikeMediaContainer]）、字幕播放列表中的 WebVTT；
/// `Content-Type` 与地址中的扩展名都由代理决定，不透传上游的值，播放器不会把内容当成其他播放列表格式。
/// 纯 Dart（dart:io），不依赖 Flutter。
class MediaProxy {
  MediaProxy._(
    this._socket,
    this._server,
    this.prepareTimeout,
    this._onLog,
    this._onTrace,
  ) {
    _server.listen(_handle, onError: (Object e) => _log('server error: $e'));
  }

  /// 在 127.0.0.1 的随机端口上启动。
  ///
  /// [log] 接收失败的诊断信息（上游失败的原因、处理请求时的异常；上游地址只记主机与路径）；
  /// [trace] 接收每个播放器请求一行（编号 / 文件名、Range、状态、字节数、耗时；不含令牌），量较大，
  /// 只在需要排查时传入。两者都同时写入 `dart:developer` 日志。
  static Future<MediaProxy> start({
    Duration prepareTimeout = const Duration(seconds: 60),
    void Function(String message)? log,
    void Function(String message)? trace,
  }) async {
    final socket = await WatchedServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final server = HttpServer.listenOn(socket)..autoCompress = false;
    return MediaProxy._(socket, server, prepareTimeout, log, trace);
  }

  final void Function(String message)? _onLog;
  final void Function(String message)? _onTrace;

  void _log(String message) {
    developer.log(message, name: 'tsumugi.media_proxy');
    _onLog?.call(message);
  }

  void _trace(String message) {
    developer.log(message, name: 'tsumugi.media_proxy');
    _onTrace?.call(message);
  }

  /// 开始向播放器发送响应体之前（取响应头、识别格式、读完播放列表 / 密钥 / 加密分片）的总时限，
  /// 超时取消上游请求。等待限速令牌的时间不计入（[SourceHttpClient.openStream] 的 `onRateLimitWait`）。
  /// 播放器任何时候断开（含排队期间）都会立即取消上游（[WatchedServerSocket]）。
  final Duration prepareTimeout;

  final WatchedServerSocket _socket;
  final HttpServer _server;
  final _sessions = <String, MediaProxySession>{};
  final _random = Random.secure();
  bool _closed = false;

  Uri get origin => Uri(scheme: 'http', host: '127.0.0.1', port: _server.port);

  /// 为一个流建立代理会话；返回的 [MediaProxySession.url] 交给播放器。
  ///
  /// [url] 为流的绝对地址，[headers] 为 `StreamRef.headers`（与客户端默认 headers 合并，
  /// 同名时 [headers] 优先）。会话用完必须 [MediaProxySession.close]。
  MediaProxySession open({
    required SourceHttpClient client,
    required Uri url,
    Map<String, String> headers = const {},
  }) {
    if (_closed) throw StateError('MediaProxy is closed');
    final token = base64Url
        .encode(List.generate(24, (_) => _random.nextInt(256)))
        .replaceAll('=', '');
    final session = MediaProxySession._(this, token, client, {
      for (final e in headers.entries) e.key.toLowerCase(): e.value,
    });
    _sessions[token] = session;
    session._root = session._register(url, _Kind.root);
    return session;
  }

  Future<void> close() async {
    _closed = true;
    for (final s in _sessions.values.toList()) {
      s.close();
    }
    await _server.close(force: true);
    // listenOn 不会关闭传入的 ServerSocket。
    await _socket.close();
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    final started = DateTime.now();
    final seg = req.uri.pathSegments;
    // 日志中不写令牌：只记编号与文件名。
    final label = seg.length == 3 ? '#${seg[1]}/${seg[2]}' : '(invalid)';
    try {
      final session = seg.length == 3 ? _sessions[seg[0]] : null;
      final index = seg.length == 3 ? int.tryParse(seg[1]) : null;
      final entry = session?._entryAt(index);
      if (session == null || entry == null) {
        return await _status(res, HttpStatus.notFound);
      }
      if (req.method != 'GET' && req.method != 'HEAD') {
        return await _status(res, HttpStatus.methodNotAllowed);
      }
      await session._serve(req, entry);
    } catch (e, st) {
      _log('${req.method} $label failed: $e\n$st');
      try {
        await _status(res, HttpStatus.badGateway);
      } catch (_) {}
    } finally {
      final range = req.headers.value(HttpHeaders.rangeHeader);
      _trace(
        '${req.method} $label'
        '${range == null ? '' : ' [$range]'} → ${res.statusCode}'
        '${res.contentLength >= 0 ? ' ${res.contentLength} B' : ''}'
        ' ${DateTime.now().difference(started).inMilliseconds} ms',
      );
    }
  }
}

/// 一次播放（一个 `StreamRef`）对应的代理会话。
class MediaProxySession {
  MediaProxySession._(this._proxy, this._token, this._client, this._headers);

  final MediaProxy _proxy;
  final String _token;
  final SourceHttpClient _client;
  final Map<String, String> _headers;
  final _entries = <_Entry>[];
  final _indexOf = <(String, _Kind, HlsAes128?), int>{};
  final _keys = <Uri, Future<(Uint8List?, int)>>{};
  final _inFlight = <NetCancellation>{};
  late final String _root;
  bool _closed = false;

  /// 会话内最多登记的地址数（直播流不断追加分片；约等于 2 s 分片的 11 小时）。
  static const maxEntries = 20000;

  /// 播放列表（改写前）的大小上限。
  static const maxPlaylistBytes = 4 * 1024 * 1024;

  /// 密钥响应的大小上限（AES-128 密钥为 16 字节）。
  static const maxKeyBytes = 4 * 1024;

  /// 需要由代理解密的 AES-128 分片（整段读入内存）的大小上限。
  static const maxEncryptedSegmentBytes = 64 * 1024 * 1024;

  /// 识别格式时读取的开头字节数。
  static const _sniffBytes = 1024;

  /// 交给播放器的地址。
  Uri get url => Uri.parse(_root);

  bool get isClosed => _closed;

  /// 最近一次上游请求失败的原因（白名单、人机验证、超时等），供界面给出对应提示。
  NetworkException? get lastFailure => _lastFailure;
  NetworkException? _lastFailure;

  /// 进行中的上游请求数（供测试检查取消）。
  int get inFlight => _inFlight.length;

  /// 撤销本会话：之后的请求返回 404，进行中的上游请求被取消。
  void close() {
    if (_closed) return;
    _closed = true;
    _proxy._sessions.remove(_token);
    for (final c in _inFlight.toList()) {
      c.cancel();
    }
    _inFlight.clear();
  }

  _Entry? _entryAt(int? index) =>
      _closed || index == null || index < 0 || index >= _entries.length
      ? null
      : _entries[index];

  /// 登记一个上游地址，返回对应的代理地址。非 http(s)、无法解析或超出数量上限的地址
  /// 也会得到一个代理地址，但请求它总是返回 403。[segmentExtension] 为 HLS 分片的扩展名
  /// （按所在播放列表第一个媒体地址的内容决定，见 [_segmentExtension]）。
  String _register(
    Uri? uri,
    _Kind kind, [
    HlsAes128? aes,
    String? segmentExtension,
  ]) {
    final index = _registerEntry(uri, kind, aes);
    final name = _fileName(_entryAt(index)?.url, kind, segmentExtension);
    return _proxy.origin
        .replace(pathSegments: [_token, '${index < 0 ? 'x' : index}', name])
        .toString();
  }

  /// 登记一个上游地址，返回编号；超出数量上限时为 -1。
  int _registerEntry(Uri? uri, _Kind kind, HlsAes128? aes) {
    bool httpUrl(Uri? u) =>
        u != null &&
        (u.scheme == 'http' || u.scheme == 'https') &&
        u.host.isNotEmpty;
    final ok = httpUrl(uri) && (aes == null || httpUrl(aes.keyUri));
    final target = ok ? uri!.removeFragment() : null;
    final key = (target?.toString() ?? '', kind, ok ? aes : null);
    var index = _indexOf[key];
    if (index == null) {
      if (_entries.length >= maxEntries) {
        index = -1;
      } else {
        index = _entries.length;
        _entries.add(_Entry(target, kind, ok ? aes : null));
        _indexOf[key] = index;
      }
    }
    return index;
  }

  Future<void> _serve(HttpRequest req, _Entry entry) async {
    final res = req.response;
    final upstream = entry.url;
    if (upstream == null) return _status(res, HttpStatus.forbidden);

    final cancel = NetCancellation();
    _inFlight.add(cancel);
    // 播放器断开（任何阶段，含限速排队期间）、响应结束或写入失败时立即取消上游请求，不等本方法返回。
    res.done.then((_) {}, onError: (Object _) {}).whenComplete(cancel.cancel);
    final unwatch = switch (req.connectionInfo?.remotePort) {
      final port? => _proxy._socket.watch(port, cancel.cancel),
      null => null,
    };
    final deadline = _deadlineFor(cancel);
    NetStreamResponse? up;
    _Rest? rest;
    try {
      if (entry.aes case final aes?) {
        return await _serveDecrypted(req, entry, upstream, aes);
      }
      final range = _forwardedRange(req, entry);
      final rangeStart = range == null ? 0 : _rangeStart(range);
      // 从中间开始的区间无法据此识别格式：先单独取开头一段确认。
      if (rangeStart != 0 && !entry.verified && entry.kind != _Kind.key) {
        final verdict = await _probe(upstream, entry, cancel);
        if (verdict != null) return await _status(res, verdict);
      }

      up = await _open(
        upstream,
        range,
        cancel,
        lane: _laneFor(entry, rangeStart: rangeStart),
      );
      if (up == null) return await _status(res, _failureStatus());
      if (_closed) return await _status(res, HttpStatus.notFound);

      final status = up.status;
      if (status < 200 || status >= 300) {
        // 重定向已由客户端逐跳处理；这里只剩错误。
        return await _status(
          res,
          status >= 400 && status < 600 ? status : HttpStatus.badGateway,
        );
      }
      final encoding = (up.headers['content-encoding'] ?? 'identity')
          .toLowerCase()
          .trim();
      // dart:io 只自动解压 gzip；其他编码、或压缩后的区间响应无法原样交给播放器。
      if (!(encoding == 'identity' ||
          (encoding == 'gzip' && status == HttpStatus.ok))) {
        return await _status(res, HttpStatus.badGateway);
      }
      final decoded = encoding != 'identity';
      final head = req.method == 'HEAD';

      final peeked = await _peek(up.body, _sniffBytes);
      final bytes = peeked.$1;
      rest = peeked.$2;
      final startsAtZero =
          status == HttpStatus.ok || _contentRangeStart(up) == 0;

      switch (entry.kind) {
        case _Kind.root || _Kind.playlist || _Kind.subtitlePlaylist
            when startsAtZero && looksLikeHlsPlaylist(bytes):
          if (range != null) {
            return await _status(res, HttpStatus.requestedRangeNotSatisfiable);
          }
          final body = await _collect(bytes, rest, maxPlaylistBytes);
          if (body == null) return await _status(res, HttpStatus.badGateway);
          final out = await _rewrite(body, up.url, entry, cancel);
          if (out == null) return await _status(res, HttpStatus.badGateway);
          res
            ..statusCode = HttpStatus.ok
            ..headers.contentType = _hlsType
            ..contentLength = out.length;
          if (!head) res.add(out);
          return await res.close();
        case _Kind.playlist || _Kind.subtitlePlaylist:
          // 子播放列表的响应不是播放列表：不交给播放器。
          return await _status(res, HttpStatus.badGateway);
        case _Kind.key:
          final body = await _collect(bytes, rest, maxKeyBytes);
          if (body == null) return await _status(res, HttpStatus.badGateway);
          res
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.binary
            ..contentLength = body.length;
          if (!head) res.add(body);
          return await res.close();
        case _Kind.root || _Kind.media || _Kind.subtitle:
          // 从开头开始的响应每次都重新识别（上游可能换了内容）；只有从中间开始、
          // 无法识别的区间才沿用之前对资源开头的确认。
          if (startsAtZero) {
            final ok = entry.kind == _Kind.subtitle
                ? looksLikeWebVtt(bytes)
                : looksLikeMediaContainer(bytes);
            // 无法识别的内容（含 HLS 以外的播放列表 / 清单、HTML 错误页、任何编码的文本）一律拒绝。
            if (!ok) return await _status(res, HttpStatus.unsupportedMediaType);
            entry.verified = true;
          }
          if (!entry.verified) {
            return await _status(res, HttpStatus.unsupportedMediaType);
          }
          res
            ..statusCode = status
            ..headers.contentType = entry.kind == _Kind.subtitle
                ? _vttType
                : ContentType.binary;
          if (!decoded) {
            for (final name in const ['content-length', 'content-range']) {
              if (up.headers[name] case final v?) res.headers.set(name, v);
            }
            if (up.headers['accept-ranges'] case final v?) {
              res.headers.set(HttpHeaders.acceptRangesHeader, v);
            }
          }
          if (head) return await res.close();
          deadline.cancel(); // 之后由读写本身的超时与失败结束
          res.add(bytes);
          await res.addStream(rest.stream);
          return await res.close();
      }
    } finally {
      unwatch?.call();
      deadline.cancel();
      _inFlight.remove(cancel);
      cancel.cancel();
      up?.cancel();
      await rest?.cancel();
    }
  }

  /// AES-128 加密的分片：取密钥与整段密文，解密（CBC + PKCS7）后确认是可识别的媒体再交给播放器。
  ///
  /// 明文按地址缓存最近几段（[_plainCacheSize]），同一分片的并发 / 重复请求只取一次上游。
  /// 播放器的 `Range` 由代理按明文处理（206 / 416）：FFmpeg 会在分片内续传或定位，
  /// 若总从开头返回整段，它拿到的数据与请求的位置对不上（Android 真机上出现过卡在分片边界）。
  Future<void> _serveDecrypted(
    HttpRequest req,
    _Entry entry,
    Uri upstream,
    HlsAes128 aes,
  ) async {
    final res = req.response;
    final (plain, status) = await _plaintext(entry, upstream, aes);
    if (plain == null) return _status(res, status);
    if (_closed) return _status(res, HttpStatus.notFound);
    final total = plain.length;
    res.headers
      ..contentType = ContentType.binary
      ..set(HttpHeaders.acceptRangesHeader, 'bytes');
    final range = req.headers.value(HttpHeaders.rangeHeader)?.trim();
    var (from, to) = (0, total - 1);
    if (range != null && range.isNotEmpty) {
      final parsed = _parseRange(range, total);
      if (parsed == null) {
        res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$total');
        return _status(res, HttpStatus.requestedRangeNotSatisfiable);
      }
      (from, to) = parsed;
      res
        ..statusCode = HttpStatus.partialContent
        ..headers.set(HttpHeaders.contentRangeHeader, 'bytes $from-$to/$total');
    } else {
      res.statusCode = HttpStatus.ok;
    }
    res.contentLength = to - from + 1;
    if (req.method != 'HEAD') {
      res.add(Uint8List.sublistView(plain, from, to + 1));
    }
    return res.close();
  }

  /// 单个区间 `bytes=a-b` / `bytes=a-` / `bytes=-n` → 闭区间 (起, 止)；
  /// 多区间、格式错误或不可满足时为 null。
  static (int, int)? _parseRange(String range, int total) {
    final m = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(range);
    if (m == null || total == 0) return null;
    final a = int.tryParse(m[1]!);
    final b = int.tryParse(m[2]!);
    if (a == null) {
      if (b == null || b == 0) return null;
      return (max(0, total - b), total - 1);
    }
    if (a >= total || (b != null && b < a)) return null;
    return (a, b == null ? total - 1 : min(b, total - 1));
  }

  static const _plainCacheSize = 4;
  final _plain = <_Entry, Future<(Uint8List?, int)>>{};

  /// 一个加密分片的明文：成功时为 (明文, 200)，失败时为 (null, 应答状态码)。失败不缓存。
  Future<(Uint8List?, int)> _plaintext(
    _Entry entry,
    Uri upstream,
    HlsAes128 aes,
  ) {
    final cached = _plain.remove(entry);
    if (cached != null) {
      _plain[entry] = cached; // 移到最近使用
      return cached;
    }
    final future = _fetchPlaintext(entry, upstream, aes);
    _plain[entry] = future;
    while (_plain.length > _plainCacheSize) {
      _plain.remove(_plain.keys.first);
    }
    future.then((r) {
      if (r.$1 == null && identical(_plain[entry], future)) {
        _plain.remove(entry);
      }
    });
    return future;
  }

  /// 与某个播放器请求无关（可能被多个请求共用）：取消只来自会话关闭与 [MediaProxy.prepareTimeout]。
  Future<(Uint8List?, int)> _fetchPlaintext(
    _Entry entry,
    Uri upstream,
    HlsAes128 aes,
  ) async {
    final (key, keyStatus) = await _key(aes.keyUri!);
    if (key == null) return (null, keyStatus);
    final cancel = NetCancellation();
    _inFlight.add(cancel);
    final deadline = _deadlineFor(cancel);
    try {
      final up = await _open(
        upstream,
        null,
        cancel,
        lane: _laneFor(entry, rangeStart: 0),
      );
      if (up == null) return (null, _failureStatus());
      try {
        if (up.status != HttpStatus.ok) {
          return (
            null,
            up.status >= 400 && up.status < 600
                ? up.status
                : HttpStatus.badGateway,
          );
        }
        final encoding = (up.headers['content-encoding'] ?? 'identity')
            .trim()
            .toLowerCase();
        if (encoding != 'identity' && encoding != 'gzip') {
          return (null, HttpStatus.badGateway);
        }
        final (head, rest) = await _peek(up.body, _sniffBytes);
        final cipherText = await _collect(head, rest, maxEncryptedSegmentBytes);
        if (cipherText == null) return (null, HttpStatus.badGateway);
        final Uint8List plain;
        try {
          final cipher =
              PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))
                ..init(
                  false,
                  PaddedBlockCipherParameters(
                    ParametersWithIV(KeyParameter(key), aes.iv),
                    null,
                  ),
                );
          plain = cipher.process(cipherText);
        } on Object {
          // 长度不是 16 的倍数、填充错误（密钥 / IV 不对）。
          return (null, HttpStatus.badGateway);
        }
        final sniff = Uint8List.sublistView(
          plain,
          0,
          min(plain.length, _sniffBytes),
        );
        if (!looksLikeMediaContainer(sniff)) {
          return (null, HttpStatus.unsupportedMediaType);
        }
        return (plain, HttpStatus.ok);
      } finally {
        up.cancel();
      }
    } on NetworkException catch (e) {
      if (e.kind != NetworkErrorKind.cancelled) _lastFailure = e;
      return (null, HttpStatus.badGateway);
    } finally {
      deadline.cancel();
      _inFlight.remove(cancel);
    }
  }

  /// 取 AES-128 密钥（每个会话按地址缓存）：成功时为 (密钥, 200)，失败时为 (null, 应答状态码)；
  /// 网络层错误的原因记在 [lastFailure]。
  Future<(Uint8List?, int)> _key(Uri uri) {
    final cached = _keys[uri];
    if (cached != null) return cached;
    final future = _fetchKey(uri);
    _keys[uri] = future;
    // 失败不缓存：下次分片请求重新取（例如用户完成验证之后）。
    future.then((k) {
      if (k.$1 == null && identical(_keys[uri], future)) _keys.remove(uri);
    });
    return future;
  }

  Future<(Uint8List?, int)> _fetchKey(Uri uri) async {
    final cancel = NetCancellation();
    _inFlight.add(cancel);
    final deadline = _deadlineFor(cancel);
    try {
      // 密钥的数量同样由分片决定（轮换密钥时每个分片一个），走媒体配额。
      final up = await _open(uri, null, cancel, lane: RateLimitLane.media);
      if (up == null) return (null, _failureStatus());
      try {
        if (up.status != HttpStatus.ok) {
          return (
            null,
            up.status >= 400 && up.status < 600
                ? up.status
                : HttpStatus.badGateway,
          );
        }
        final (head, rest) = await _peek(up.body, 64);
        final bytes = await _collect(head, rest, maxKeyBytes);
        return bytes != null && bytes.length == 16
            ? (bytes, HttpStatus.ok)
            : (null, HttpStatus.badGateway);
      } finally {
        up.cancel();
      }
    } on NetworkException catch (e) {
      if (e.kind != NetworkErrorKind.cancelled) _lastFailure = e;
      return (null, HttpStatus.badGateway);
    } finally {
      deadline.cancel();
      _inFlight.remove(cancel);
    }
  }

  /// 转发给上游的 `Range`；播放列表与密钥不转发，根地址的 `bytes=0-`（ffmpeg 的默认首个请求）不转发，
  /// 以便识别根地址是否为播放列表。
  static String? _forwardedRange(HttpRequest req, _Entry entry) {
    final range = req.headers.value(HttpHeaders.rangeHeader)?.trim();
    if (range == null || range.isEmpty) return null;
    return switch (entry.kind) {
      _Kind.playlist || _Kind.subtitlePlaylist || _Kind.key => null,
      _Kind.root when range == 'bytes=0-' => null,
      _ => range,
    };
  }

  /// `bytes=N-…` 的 N；后缀区间（`bytes=-N`）或无法解析时返回 -1（视为不从开头开始）。
  static int _rangeStart(String range) =>
      int.tryParse(
        RegExp(r'^bytes=(\d+)-').firstMatch(range)?.group(1) ?? '',
      ) ??
      -1;

  static int? _contentRangeStart(NetStreamResponse up) => int.tryParse(
    RegExp(r'^bytes (\d+)-')
            .firstMatch(up.headers['content-range'] ?? '')
            ?.group(1) ??
        '',
  );

  /// [entry] 的上游请求计入哪个令牌桶（source-spec §5）。[rangeStart] 为本次请求的区间起点
  /// （不带区间为 0，后缀区间为 -1）。
  ///
  /// 分片（含字幕分片、加密分片的密文）与密钥（数量由分片决定，轮换密钥时每个分片一个）走本源的媒体配额；
  /// 根地址只有在确认是媒体之后、且不从开头开始的请求（跳转时的区间请求）才走媒体配额——从开头开始的响应
  /// 每次都会重新识别，可能是播放列表，因此计入 `rateLimit`。播放列表计入 `rateLimit`。
  static RateLimitLane _laneFor(_Entry entry, {required int rangeStart}) =>
      switch (entry.kind) {
        _Kind.media || _Kind.subtitle || _Kind.key => RateLimitLane.media,
        _Kind.root when entry.verified && rangeStart != 0 =>
          RateLimitLane.media,
        _ => RateLimitLane.source,
      };

  /// [cancel] 对应的 `prepareTimeout`：到时取消 [cancel]；经 [_open] 等待限速令牌期间暂停。
  PausableDeadline _deadlineFor(NetCancellation cancel) => _deadlines[cancel] =
      PausableDeadline(_proxy.prepareTimeout, cancel.cancel);
  final _deadlines = Expando<PausableDeadline>();

  Future<NetStreamResponse?> _open(
    Uri upstream,
    String? range,
    NetCancellation cancel, {
    required RateLimitLane lane,
  }) async {
    final deadline = _deadlines[cancel];
    try {
      return await _client.openStream(
        lane: lane,
        onRateLimitWait: deadline == null
            ? null
            : (waiting) => waiting ? deadline.pause() : deadline.resume(),
        NetRequest(
          upstream.toString(),
          headers: {
            ..._headers,
            // 区间请求要求按原样字节传输；放在 StreamRef.headers 之后，不允许被覆盖。
            'accept-encoding': 'identity',
            'range': ?range,
          },
          cancellation: cancel,
        ),
      );
    } on NetworkException catch (e) {
      if (e.kind != NetworkErrorKind.cancelled) {
        _lastFailure = e;
        _proxy._log(
          'upstream failed: ${e.kind.name} '
          '${(e.uri ?? upstream).replace(query: '')}',
        );
      }
      return null;
    }
  }

  int _failureStatus() => switch (_lastFailure?.kind) {
    NetworkErrorKind.hostNotAllowed ||
    NetworkErrorKind.challenge => HttpStatus.forbidden,
    NetworkErrorKind.timeout => HttpStatus.gatewayTimeout,
    _ => HttpStatus.badGateway,
  };

  /// 取资源开头一段识别格式；可以继续时返回 null，否则返回应答状态码。
  Future<int?> _probe(
    Uri upstream,
    _Entry entry,
    NetCancellation cancel,
  ) async {
    final (bytes, status) = await _head(upstream, entry, cancel);
    if (bytes == null) return status;
    final ok = entry.kind == _Kind.subtitle
        ? looksLikeWebVtt(bytes)
        : looksLikeMediaContainer(bytes);
    if (!ok) return HttpStatus.unsupportedMediaType;
    entry.verified = true;
    return null;
  }

  /// 资源从 [offset] 起的 [length] 字节（默认开头 [_sniffBytes] 字节）：成功时为 (字节, 200)，
  /// 失败时为 (null, 应答状态码)。[offset] 不为 0 时上游必须按区间返回（206，起点一致）。
  Future<(Uint8List?, int)> _head(
    Uri upstream,
    _Entry entry,
    NetCancellation cancel, [
    int length = _sniffBytes,
    int offset = 0,
  ]) async {
    final up = await _open(
      upstream,
      'bytes=$offset-${offset + length - 1}',
      cancel,
      lane: _laneFor(entry, rangeStart: 0),
    );
    if (up == null) return (null, _failureStatus());
    try {
      if (up.status != HttpStatus.ok &&
          up.status != HttpStatus.partialContent) {
        return (
          null,
          up.status >= 400 && up.status < 600
              ? up.status
              : HttpStatus.badGateway,
        );
      }
      if (offset != 0 &&
          (up.status != HttpStatus.partialContent ||
              _contentRangeStart(up) != offset)) {
        return (null, HttpStatus.badGateway);
      }
      final (bytes, rest) = await _peek(up.body, length);
      await rest.cancel();
      return (bytes, HttpStatus.ok);
    } finally {
      up.cancel();
    }
  }

  /// 探测分片内容时最多读取的字节数（ID3 标签较大时补读到其后的帧头）。
  static const _maxProbeBytes = 64 * 1024;

  /// 每个播放列表最多探测几次分片内容（失败后直播刷新时再试，之后固定为 `ts`）。
  static const maxSegmentProbes = 2;

  /// 按 [entry]（FFmpeg 起播时探测的那个媒体地址）的内容决定该播放列表中分片的扩展名；
  /// 无法取得或识别时为 null。
  ///
  /// FFmpeg 7.1.1 起，HLS 解复用器要求每个分片地址的扩展名与探测出的格式一致（architecture §6.4.3）。
  /// 只取开头一段（区间请求）：加密分片只解密开头几块（CBC 按块解密，不需要整段）。
  /// 整个过程受播放列表请求的 [cancel]（断开、`prepareTimeout`）约束。
  ///
  /// [range] 为该地址在播放列表中的字节区间（`EXT-X-BYTERANGE` / `EXT-X-MAP` 的 `BYTERANGE`）：
  /// FFmpeg 探测的是这一段，因此从它的起点读（不超过它的长度）。
  Future<String?> _segmentExtension(
    _Entry entry,
    NetCancellation cancel, [
    (int, int)? range,
  ]) async {
    final (offset, limit) = range ?? (0, _maxProbeBytes);
    if (limit <= 0) return null;
    var head = await _probeHead(entry, min(_sniffBytes, limit), cancel, offset);
    var container = head == null ? null : sniffMediaContainer(head);
    if (container == MediaContainer.id3) {
      final need = id3FrameOffset(head!)! + 6;
      if (need <= min(_maxProbeBytes, limit)) {
        head = await _probeHead(entry, need, cancel, offset);
        if (head != null) container = sniffMediaContainer(head) ?? container;
      }
    }
    if (container == null) return null;
    // 只有从资源开头识别时才算确认了资源本身（之后从中间开始的区间请求沿用）。
    if (entry.aes == null && offset == 0) entry.verified = true;
    return container.extension;
  }

  /// [entry] 开头最多 [length] 字节的明文；失败或被取消时为 null。
  Future<Uint8List?> _probeHead(
    _Entry entry,
    int length,
    NetCancellation cancel, [
    int offset = 0,
  ]) async {
    final upstream = entry.url;
    if (upstream == null) return null;
    final aes = entry.aes;
    if (aes == null) {
      return (await _head(upstream, entry, cancel, length, offset)).$1;
    }
    // AES-128 与字节区间同时使用不支持（地址总是 403），不会走到这里。
    if (offset != 0) return null;
    // 密钥按会话缓存、与分片请求共用；探测不等到它超出播放列表请求的时限（取密钥本身继续，结果照常缓存）。
    final keyResult = await Future.any([
      _key(aes.keyUri!).then<(Uint8List?, int)?>((r) => r),
      cancel.whenCancelled.then<(Uint8List?, int)?>((_) => null),
    ]);
    final key = keyResult?.$1;
    if (key == null || cancel.isCancelled) return null;
    final blocks = (length + 15) ~/ 16 * 16;
    final (cipherText, _) = await _head(upstream, entry, cancel, blocks);
    if (cipherText == null || cipherText.length < 16) return null;
    try {
      final cipher = CBCBlockCipher(AESEngine())
        ..init(false, ParametersWithIV(KeyParameter(key), aes.iv));
      final n = cipherText.length ~/ 16 * 16;
      final plain = Uint8List(n);
      for (var off = 0; off < n; off += 16) {
        cipher.processBlock(cipherText, off, plain, off);
      }
      // 末块可能含 PKCS7 填充：只用于识别，不影响结果。
      return Uint8List.sublistView(plain, 0, min(n, length));
    } on Object {
      return null;
    }
  }

  /// 选出 FFmpeg 起播时用来探测格式的媒体地址（n7.1.1 / n8.0.1 `hls_read_header` 与 `select_cur_seq_no`）：
  /// 有 `EXT-X-MAP` 时为初始化分片（与分片一起探测，由它决定格式）；否则点播为第一个分片，
  /// 直播（没有 `EXT-X-ENDLIST`）为倒数第 3 个分片（`live_start_index` 默认 -3）。
  /// 部分分片（`EXT-X-PART` / `EXT-X-PRELOAD-HINT`）不算。没有可用地址时为 null。
  static (Uri, HlsAes128?, (int, int)?)? _probeTarget(String text, Uri base) {
    (Uri?, HlsAes128?, (int, int)?)? init;
    final segments = <(Uri?, HlsAes128?, (int, int)?)>[];
    (int, int)? range;
    rewriteHlsPlaylist(
      text,
      base: base,
      onByteRange: (o, n) => range = (o, n),
      map: (uri, k, [aes]) {
        if (k == HlsUriKind.init) init ??= (uri, aes, range);
        if (k == HlsUriKind.media) segments.add((uri, aes, range));
        range = null;
        return '';
      },
    );
    final live = !_endList.hasMatch(text);
    final target =
        init ??
        (segments.isEmpty
            ? null
            : segments[live ? max(0, segments.length - 3) : 0]);
    return switch (target) {
      (final Uri uri, final aes, final range) => (uri, aes, range),
      _ => null,
    };
  }

  static final _endList = RegExp(r'^\s*#EXT-X-ENDLIST\s*$', multiLine: true);

  /// 改写 [playlist] 的响应。其中有分片时，分片的扩展名按 FFmpeg 起播时探测的那个媒体地址的内容决定
  /// （[_probeTarget]、[_segmentExtension]；识别成功后沿用，最多探测 [maxSegmentProbes] 次）；
  /// 识别失败时用 `ts`。
  Future<Uint8List?> _rewrite(
    Uint8List body,
    Uri base,
    _Entry playlist,
    NetCancellation cancel,
  ) async {
    final text = utf8.decode(body, allowMalformed: true);
    _Kind kindOf(HlsUriKind k) => switch (k) {
      HlsUriKind.playlist => _Kind.playlist,
      HlsUriKind.subtitlePlaylist => _Kind.subtitlePlaylist,
      HlsUriKind.media || HlsUriKind.init || HlsUriKind.part
          when playlist.kind == _Kind.subtitlePlaylist =>
        _Kind.subtitle,
      HlsUriKind.media || HlsUriKind.init || HlsUriKind.part => _Kind.media,
      HlsUriKind.key => _Kind.key,
    };
    try {
      var ext = playlist.segmentExtension;
      if (ext == null &&
          playlist.kind != _Kind.subtitlePlaylist &&
          playlist.segmentProbes < maxSegmentProbes) {
        // 第一遍只找要探测的地址（不登记任何地址）。
        if (_probeTarget(text, base) case (final uri, final aes, final range)) {
          playlist.segmentProbes++;
          final entry = _entryAt(_registerEntry(uri, _Kind.media, aes));
          ext = entry == null
              ? null
              : await _segmentExtension(entry, cancel, range);
          playlist.segmentExtension = ext;
        }
      }
      return utf8.encode(
        rewriteHlsPlaylist(
          text,
          base: base,
          map: (uri, k, [aes]) => _register(uri, kindOf(k), aes, ext),
        ),
      );
    } on FormatException {
      return null;
    }
  }

  static final _hlsType = ContentType('application', 'vnd.apple.mpegurl');
  static final _vttType = ContentType('text', 'vtt', charset: 'utf-8');

  /// 代理地址中的文件名：只给播放器看（FFmpeg 的 HLS 分片扩展名检查），不参与查找。
  /// 扩展名只用媒体或 HLS 的扩展名，避免播放器按扩展名把内容当成其他播放列表格式（architecture §6.4.3）：
  /// HLS 分片用 [segmentExtension]（按内容决定，见 [MediaContainer.extension]；未知时为 `ts`），
  /// 根地址按上游扩展名只保留常见媒体扩展名，其余换成 `.bin`。
  static String _fileName(Uri? uri, _Kind kind, String? segmentExtension) {
    switch (kind) {
      case _Kind.playlist || _Kind.subtitlePlaylist:
        return 'index.m3u8';
      case _Kind.key:
        return 'key.bin';
      case _Kind.subtitle:
        return 'sub.vtt';
      case _Kind.media:
        return 'media.${segmentExtension ?? 'ts'}';
      case _Kind.root:
        final last =
            uri?.pathSegments.where((s) => s.isNotEmpty).lastOrNull ?? '';
        final dot = last.lastIndexOf('.');
        final ext = dot < 0 ? '' : last.substring(dot + 1).toLowerCase();
        if (ext == 'm3u8' || ext == 'm3u') {
          return 'index.m3u8';
        }
        return _mediaExtensions.contains(ext) ? 'media.$ext' : 'media.bin';
    }
  }

  static const _mediaExtensions = {
    'ts', 'm2ts', 'mts', 'mp4', 'm4s', 'm4v', 'm4a', 'mov', 'cmfv', 'cmfa', //
    'aac', 'ac3', 'ec3', 'mp3', 'mp2', 'flac', 'ogg', 'oga', 'opus', 'wav',
    'webm', 'mkv', 'flv', 'avi', 'mpg', 'mpeg',
  };
}

enum _Kind { root, playlist, subtitlePlaylist, media, subtitle, key }

class _Entry {
  _Entry(this.url, this.kind, this.aes);

  /// null：不允许请求（非 http(s) 或无法解析）。
  final Uri? url;
  final _Kind kind;

  /// 非 null 时由代理按 AES-128 解密后交给播放器。
  final HlsAes128? aes;

  /// 已从资源开头确认是可识别的媒体（之后从中间开始的区间请求沿用；从开头开始的响应每次都重新识别）。
  bool verified = false;

  /// 播放列表：其中分片的扩展名（探测分片内容成功后记下，之后的刷新沿用）。
  String? segmentExtension;

  /// 播放列表：已探测分片内容的次数（上限 [MediaProxySession.maxSegmentProbes]）。
  int segmentProbes = 0;
}

/// 读出前 [n] 字节（或直到流结束），剩余部分由返回的 [_Rest] 继续读取。
Future<(Uint8List, _Rest)> _peek(Stream<List<int>> body, int n) async {
  final it = StreamIterator(body);
  final head = BytesBuilder(copy: false);
  final pending = <List<int>>[];
  while (head.length < n && await it.moveNext()) {
    final chunk = it.current;
    final take = min(n - head.length, chunk.length);
    head.add(chunk.sublist(0, take));
    if (take < chunk.length) pending.add(chunk.sublist(take));
  }
  return (head.takeBytes(), _Rest(it, pending));
}

class _Rest {
  _Rest(this._it, this._pending);

  final StreamIterator<List<int>> _it;
  final List<List<int>> _pending;

  Stream<List<int>> get stream async* {
    try {
      yield* Stream.fromIterable(_pending);
      while (await _it.moveNext()) {
        yield _it.current;
      }
    } finally {
      await _it.cancel();
    }
  }

  Future<void> cancel() => _it.cancel();
}

/// 把 [head] 与剩余部分读成一个字节数组；超过 [limit] 时返回 null。
Future<Uint8List?> _collect(Uint8List head, _Rest rest, int limit) async {
  final out = BytesBuilder(copy: false)..add(head);
  await for (final chunk in rest.stream) {
    out.add(chunk);
    if (out.length > limit) return null;
  }
  return out.takeBytes();
}

Future<void> _status(HttpResponse res, int status) {
  res.statusCode = status;
  res.contentLength = 0;
  return res.close();
}
