import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import '../network_exception.dart';
import '../source_http_client.dart';
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
  MediaProxy._(this._server, this.prepareTimeout) {
    _server.listen(_handle, onError: (Object e) => _log('server error: $e'));
  }

  /// 在 127.0.0.1 的随机端口上启动。
  static Future<MediaProxy> start({
    Duration prepareTimeout = const Duration(seconds: 60),
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.autoCompress = false;
    return MediaProxy._(server, prepareTimeout);
  }

  /// 开始向播放器发送响应体之前（取响应头、识别格式、读完播放列表 / 密钥 / 加密分片）的总时限，
  /// 超时取消上游请求。dart:io 在写入之前察觉不到播放器断开，这个时限保证被放弃的请求不会一直挂着；
  /// 开始发送之后，播放器断开会让写入失败并立即取消上游。
  final Duration prepareTimeout;

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
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      final seg = req.uri.pathSegments;
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
      _log('${req.method} ${req.uri.path} failed: $e\n$st');
      try {
        await _status(res, HttpStatus.badGateway);
      } catch (_) {}
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
  /// 也会得到一个代理地址，但请求它总是返回 403。
  String _register(Uri? uri, _Kind kind, [HlsAes128? aes]) {
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
    final name = _fileName(ok ? uri : null, kind);
    return _proxy.origin
        .replace(pathSegments: [_token, '${index < 0 ? 'x' : index}', name])
        .toString();
  }

  Future<void> _serve(HttpRequest req, _Entry entry) async {
    final res = req.response;
    final upstream = entry.url;
    if (upstream == null) return _status(res, HttpStatus.forbidden);

    final cancel = NetCancellation();
    _inFlight.add(cancel);
    // 响应结束或写入失败（播放器断开）时立即取消上游请求，不等本方法返回。
    res.done.then((_) {}, onError: (Object _) {}).whenComplete(cancel.cancel);
    final deadline = Timer(_proxy.prepareTimeout, cancel.cancel);
    NetStreamResponse? up;
    _Rest? rest;
    try {
      if (entry.aes case final aes?) {
        return await _serveDecrypted(req, upstream, aes, cancel);
      }
      final range = _forwardedRange(req, entry);
      final rangeStart = range == null ? 0 : _rangeStart(range);
      // 从中间开始的区间无法据此识别格式：先单独取开头一段确认。
      if (rangeStart != 0 && !entry.verified && entry.kind != _Kind.key) {
        final verdict = await _probe(upstream, entry, cancel);
        if (verdict != null) return await _status(res, verdict);
      }

      up = await _open(upstream, range, cancel);
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
          final out = _rewrite(body, up.url, entry.kind);
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
      deadline.cancel();
      _inFlight.remove(cancel);
      cancel.cancel();
      up?.cancel();
      await rest?.cancel();
    }
  }

  /// AES-128 加密的分片：取密钥与整段密文，解密（CBC + PKCS7）后确认是可识别的媒体再交给播放器。
  /// 播放器的 `Range` 不转发（整段返回 200）。
  Future<void> _serveDecrypted(
    HttpRequest req,
    Uri upstream,
    HlsAes128 aes,
    NetCancellation cancel,
  ) async {
    final res = req.response;
    final (key, keyStatus) = await _key(aes.keyUri!);
    if (key == null) return _status(res, keyStatus);
    final up = await _open(upstream, null, cancel);
    if (up == null) return _status(res, _failureStatus());
    try {
      if (up.status != HttpStatus.ok) {
        return await _status(
          res,
          up.status >= 400 && up.status < 600
              ? up.status
              : HttpStatus.badGateway,
        );
      }
      final encoding = (up.headers['content-encoding'] ?? 'identity')
          .trim()
          .toLowerCase();
      if (encoding != 'identity' && encoding != 'gzip') {
        return await _status(res, HttpStatus.badGateway);
      }
      final (head, rest) = await _peek(up.body, _sniffBytes);
      final cipherText = await _collect(head, rest, maxEncryptedSegmentBytes);
      if (cipherText == null) return await _status(res, HttpStatus.badGateway);
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
        return await _status(res, HttpStatus.badGateway);
      }
      final sniff = Uint8List.sublistView(
        plain,
        0,
        min(plain.length, _sniffBytes),
      );
      if (!looksLikeMediaContainer(sniff)) {
        return await _status(res, HttpStatus.unsupportedMediaType);
      }
      res
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.binary
        ..contentLength = plain.length;
      if (req.method != 'HEAD') res.add(plain);
      return await res.close();
    } finally {
      up.cancel();
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
    final deadline = Timer(_proxy.prepareTimeout, cancel.cancel);
    try {
      final up = await _open(uri, null, cancel);
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

  Future<NetStreamResponse?> _open(
    Uri upstream,
    String? range,
    NetCancellation cancel,
  ) async {
    try {
      return await _client.openStream(
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
        _log('upstream failed: ${e.kind.name} ${e.uri ?? upstream}');
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
    final up = await _open(upstream, 'bytes=0-${_sniffBytes - 1}', cancel);
    if (up == null) return _failureStatus();
    try {
      if (up.status != HttpStatus.ok &&
          up.status != HttpStatus.partialContent) {
        return up.status >= 400 && up.status < 600
            ? up.status
            : HttpStatus.badGateway;
      }
      final (bytes, rest) = await _peek(up.body, _sniffBytes);
      await rest.cancel();
      final ok = entry.kind == _Kind.subtitle
          ? looksLikeWebVtt(bytes)
          : looksLikeMediaContainer(bytes);
      if (!ok) return HttpStatus.unsupportedMediaType;
      entry.verified = true;
      return null;
    } finally {
      up.cancel();
    }
  }

  Uint8List? _rewrite(Uint8List body, Uri base, _Kind kind) {
    try {
      return utf8.encode(
        rewriteHlsPlaylist(
          utf8.decode(body, allowMalformed: true),
          base: base,
          map: (uri, k, [aes]) => _register(uri, switch (k) {
            HlsUriKind.playlist => _Kind.playlist,
            HlsUriKind.subtitlePlaylist => _Kind.subtitlePlaylist,
            HlsUriKind.media when kind == _Kind.subtitlePlaylist =>
              _Kind.subtitle,
            HlsUriKind.media => _Kind.media,
            HlsUriKind.key => _Kind.key,
          }, aes),
        ),
      );
    } on FormatException {
      return null;
    }
  }

  static final _hlsType = ContentType('application', 'vnd.apple.mpegurl');
  static final _vttType = ContentType('text', 'vtt', charset: 'utf-8');

  /// 代理地址中的文件名：只用于让 FFmpeg 的 HLS 分片扩展名检查通过，不参与查找。
  /// 扩展名只保留常见媒体扩展名，其余换成 `.bin`，避免播放器按扩展名把内容当成其他播放列表格式。
  static String _fileName(Uri? uri, _Kind kind) {
    switch (kind) {
      case _Kind.playlist || _Kind.subtitlePlaylist:
        return 'index.m3u8';
      case _Kind.key:
        return 'key.bin';
      case _Kind.subtitle:
        return 'sub.vtt';
      case _Kind.root || _Kind.media:
        final last =
            uri?.pathSegments.where((s) => s.isNotEmpty).lastOrNull ?? '';
        final dot = last.lastIndexOf('.');
        final ext = dot < 0 ? '' : last.substring(dot + 1).toLowerCase();
        if (kind == _Kind.root && (ext == 'm3u8' || ext == 'm3u')) {
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

void _log(String message) =>
    developer.log(message, name: 'tsumugi.media_proxy');
