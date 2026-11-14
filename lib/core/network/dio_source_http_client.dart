import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';

import 'network_exception.dart';
import 'rate_limiter.dart';
import 'source_http_client.dart';
import 'source_session.dart';

/// 基于 dio + cookie_jar 的 [SourceHttpClient] 实现。
///
/// 重定向由本类逐跳处理（dio 本身不跟随），以便对每一跳执行白名单检查。
class DioSourceHttpClient implements SourceHttpClient {
  /// [session] 为本源的会话（与同一源的其他客户端共用 Cookie 与 UA）；未给出时新建一个，
  /// 其 Cookie Jar 为 [cookieJar]（默认内存 Jar）。
  /// [adapter] 仅用于测试或特殊传输层（例如把虚构域名路由到本地 mock 服务器）。
  DioSourceHttpClient(
    this.config, {
    SourceSession? session,
    CookieJar? cookieJar,
    HttpClientAdapter? adapter,
  }) : assert(session == null || cookieJar == null),
       session = session ?? SourceSession(cookieJar: cookieJar),
       _bucket = switch (config.rateLimit) {
         final r? => TokenBucket(requests: r.requests, per: r.per),
         null => null,
       } {
    // 不使用 dio 自带的超时：每次尝试的总时长由 [_attempt] 的计时器统一控制，
    // 这样请求级 timeout 可以放宽或收紧默认值。
    _dio = Dio();
    if (adapter != null) _dio.httpClientAdapter = adapter;
    _dio.interceptors.add(CookieManager(this.session.cookieJar));
  }

  @override
  final SourceNetworkConfig config;
  @override
  final SourceSession session;
  CookieJar get cookieJar => session.cookieJar;
  final TokenBucket? _bucket;
  late final Dio _dio;

  static const _methods = {
    'GET',
    'POST',
    'PUT',
    'DELETE',
    'HEAD',
    'PATCH',
    'OPTIONS',
  };
  static const _idempotent = {'GET', 'HEAD', 'PUT', 'DELETE', 'OPTIONS'};

  @override
  Future<NetResponse> request(NetRequest request) async {
    var method = request.method.toUpperCase();
    if (!_methods.contains(method)) {
      throw NetworkException(
        NetworkErrorKind.invalidRequest,
        message: 'unsupported method: ${request.method}',
      );
    }
    var uri = _checkedUri(request.url);
    final headers = await _headersFor(request);
    List<int>? body;
    if (request.body case final b?) {
      body = b.encode();
      headers.putIfAbsent('content-type', () => b.defaultContentType);
    }
    final timeout = request.timeout ?? config.timeout;

    for (var hop = 0; ; hop++) {
      final raw = await _sendWithRetry(
        method,
        uri,
        headers,
        body,
        timeout,
        request.cancellation,
      );
      final location = raw.headers['location']?.firstOrNull;
      if (request.followRedirects &&
          _isRedirect(raw.status) &&
          location != null) {
        if (hop >= config.maxRedirects) {
          throw NetworkException(
            NetworkErrorKind.tooManyRedirects,
            message: 'more than ${config.maxRedirects} redirects',
            uri: uri,
          );
        }
        final next = _checkedUri(location, base: uri);
        if (raw.status == 303 ||
            ((raw.status == 301 || raw.status == 302) &&
                method != 'GET' &&
                method != 'HEAD')) {
          method = 'GET';
          body = null;
          headers
            ..remove('content-type')
            ..remove('content-length');
        }
        _stripCredentialsAcrossHosts(headers, uri, next);
        uri = next;
        continue;
      }

      final response = NetResponse(
        status: raw.status,
        url: uri,
        headersAll: raw.headers,
        bytes: raw.bytes,
      );
      if (request.throwOnHttpError) {
        final acceptable =
            response.ok ||
            (!request.followRedirects && _isRedirect(response.status));
        if (!acceptable) {
          throw NetworkException(
            NetworkErrorKind.http,
            message: 'HTTP ${raw.status}',
            uri: uri,
            status: raw.status,
          );
        }
      }
      return response;
    }
  }

  @override
  Future<NetStreamResponse> openStream(NetRequest request) async {
    final method = request.method.toUpperCase();
    if (method != 'GET' && method != 'HEAD') {
      throw NetworkException(
        NetworkErrorKind.invalidRequest,
        message: 'openStream supports GET / HEAD only: ${request.method}',
      );
    }
    if (request.body != null || request.throwOnHttpError) {
      throw NetworkException(
        NetworkErrorKind.invalidRequest,
        message: 'openStream does not support a body or throwOnHttpError',
      );
    }
    var uri = _checkedUri(request.url);
    final headers = await _headersFor(request);
    final timeout = request.timeout ?? config.timeout;

    for (var hop = 0; ; hop++) {
      final raw = await _openWithRetry(
        method,
        uri,
        headers,
        timeout,
        request.cancellation,
      );
      final location = raw.headers['location']?.firstOrNull;
      if (request.followRedirects &&
          _isRedirect(raw.status) &&
          location != null) {
        raw.cancel();
        if (hop >= config.maxRedirects) {
          throw NetworkException(
            NetworkErrorKind.tooManyRedirects,
            message: 'more than ${config.maxRedirects} redirects',
            uri: uri,
          );
        }
        // GET / HEAD 在任何重定向后都保持原方法（303 的“改为 GET”对二者无影响）。
        final next = _checkedUri(location, base: uri);
        _stripCredentialsAcrossHosts(headers, uri, next);
        uri = next;
        continue;
      }
      return NetStreamResponse(
        status: raw.status,
        url: uri,
        headersAll: raw.headers,
        body: raw.body,
        onCancel: raw.cancel,
      );
    }
  }

  @override
  Future<Map<String, String>> getCookies(String url) async {
    final cookies = await cookieJar.loadForRequest(_checkedUri(url));
    return {for (final c in cookies) c.name: c.value};
  }

  @override
  Future<void> setCookie(String url, String name, String value) async {
    final uri = _checkedUri(url);
    final Cookie cookie;
    try {
      cookie = Cookie(name, value)..path = '/';
    } on FormatException catch (e) {
      throw NetworkException(
        NetworkErrorKind.invalidRequest,
        message: 'invalid cookie: ${e.message}',
        uri: uri,
        cause: e,
      );
    }
    await cookieJar.saveFromResponse(uri, [cookie]);
  }

  @override
  Future<void> clearCookies() => cookieJar.deleteAll();

  @override
  void close() => _dio.close(force: true);

  // ---------------------------------------------------------------------------

  /// 默认 headers + 请求 headers（同名时请求优先，名称一律小写）+ 会话 UA（未显式指定时）。
  Future<Map<String, String>> _headersFor(NetRequest request) async {
    final headers = <String, String>{
      for (final e in config.defaultHeaders.entries)
        e.key.toLowerCase(): e.value,
      for (final e in request.headers.entries) e.key.toLowerCase(): e.value,
    };
    await session.ready; // 持久化会话（含 UA）加载完成
    if (session.userAgent case final ua? when ua.isNotEmpty) {
      headers.putIfAbsent('user-agent', () => ua);
    }
    return headers;
  }

  /// 跨主机重定向时不把调用方显式设置的凭据带到其他主机；
  /// Jar 中的 Cookie 由 CookieManager 按域名附加。
  static void _stripCredentialsAcrossHosts(
    Map<String, String> headers,
    Uri from,
    Uri to,
  ) {
    if (to.host != from.host) {
      headers
        ..remove('authorization')
        ..remove('cookie');
    }
  }

  /// 流式请求的重试循环：与 [_sendWithRetry] 相同的限速、连接错误 / 5xx 重试与挑战检测，
  /// 但只在拿到响应头之前重试。
  Future<_RawStream> _openWithRetry(
    String method,
    Uri uri,
    Map<String, String> headers,
    Duration timeout,
    NetCancellation? cancellation,
  ) async {
    for (var attempt = 0; ; attempt++) {
      _throwIfCancelled(cancellation, uri);
      if (_bucket case final bucket?) {
        final acquired = await bucket.acquire(
          abort: cancellation?.whenCancelled,
        );
        if (!acquired) {
          throw NetworkException(NetworkErrorKind.cancelled, uri: uri);
        }
      }
      _throwIfCancelled(cancellation, uri);

      final canRetry = attempt < config.maxRetries;
      _RawStream raw;
      try {
        raw = await _openAttempt(method, uri, headers, timeout, cancellation);
      } on NetworkException catch (e) {
        if (canRetry && e.kind == NetworkErrorKind.connection) {
          await _backoff(attempt);
          continue;
        }
        rethrow;
      }

      final detector = config.challengeDetector;
      if (detector.statuses.contains(raw.status)) {
        // 只读出检测所需的开头一段（不限制整个响应体的大小），之后与剩余部分拼接后交给调用方。
        final it = StreamIterator(raw.body);
        final prefix = BytesBuilder(copy: false);
        var more = true;
        try {
          while (prefix.length < detector.scanBytes &&
              (more = await it.moveNext())) {
            prefix.add(it.current);
          }
        } catch (_) {
          await it.cancel();
          raw.cancel();
          rethrow;
        }
        final bytes = prefix.takeBytes();
        if (detector.isChallenge(raw.status, raw.headers, bytes)) {
          await it.cancel();
          raw.cancel();
          session.lastChallengeUrl = uri;
          throw NetworkException(
            NetworkErrorKind.challenge,
            message: 'human verification required',
            uri: uri,
            status: raw.status,
          );
        }
        raw = raw.withBody(_prefixed(bytes, it, more));
      }
      if (canRetry && raw.status >= 500 && raw.status < 600) {
        raw.cancel();
        await _backoff(attempt);
        continue;
      }
      return raw;
    }
  }

  /// [prefix] 之后接着 [rest] 中尚未读取的部分（[more] 为 false 表示已读完）。
  static Stream<List<int>> _prefixed(
    Uint8List prefix,
    StreamIterator<List<int>> rest,
    bool more,
  ) async* {
    try {
      if (prefix.isNotEmpty) yield prefix;
      if (!more) return;
      while (await rest.moveNext()) {
        yield rest.current;
      }
    } finally {
      await rest.cancel();
    }
  }

  /// 单次流式尝试：[timeout] 限制等待响应头的时间；之后由 [_guardBody] 限制相邻两块数据的间隔。
  Future<_RawStream> _openAttempt(
    String method,
    Uri uri,
    Map<String, String> headers,
    Duration timeout,
    NetCancellation? cancellation,
  ) async {
    final token = CancelToken();
    cancellation?.whenCancelled.then((_) => token.cancel('cancelled'));
    final abort = Completer<Response<ResponseBody>>();
    final timer = Timer(timeout, () {
      if (abort.isCompleted) return;
      abort.completeError(
        NetworkException(
          NetworkErrorKind.timeout,
          message: 'timed out after ${timeout.inMilliseconds} ms',
          uri: uri,
        ),
      );
      token.cancel('timeout');
    });
    final Response<ResponseBody> response;
    try {
      response = await Future.any([
        _dio.requestUri<ResponseBody>(
          uri,
          cancelToken: token,
          options: Options(
            method: method,
            headers: headers,
            followRedirects: false,
            validateStatus: (_) => true,
            responseType: ResponseType.stream,
          ),
        ),
        abort.future,
      ]);
    } on DioException catch (e) {
      throw _mapDioException(e, uri);
    } finally {
      timer.cancel();
    }
    final status = response.statusCode ?? 0;
    final source = response.data!.stream;
    return _RawStream(
      status,
      response.headers.map,
      method == 'HEAD'
          ? const Stream.empty()
          : _guardBody(source, uri, token, timeout),
      token,
    );
  }

  /// 把响应体的错误统一为 [NetworkException]，并在相邻两块数据间隔超过 [idle] 时以超时结束。
  /// 调用方取消订阅时中止请求、释放连接（dio 的流本身不会因取消订阅而中止请求）。
  Stream<List<int>> _guardBody(
    Stream<Uint8List> source,
    Uri uri,
    CancelToken token,
    Duration idle,
  ) {
    final guarded = source
        .timeout(
          idle,
          onTimeout: (sink) {
            token.cancel('idle timeout');
            sink
              ..addError(
                NetworkException(
                  NetworkErrorKind.timeout,
                  message: 'no data for ${idle.inMilliseconds} ms',
                  uri: uri,
                ),
              )
              ..close();
          },
        )
        .transform(
          StreamTransformer<Uint8List, List<int>>.fromHandlers(
            handleError: (e, st, sink) => sink.addError(switch (e) {
              NetworkException() => e,
              DioException() => _mapDioException(e, uri),
              _ => NetworkException(
                NetworkErrorKind.connection,
                message: 'error while reading body: $e',
                uri: uri,
                cause: e,
              ),
            }, st),
          ),
        );
    late final StreamController<List<int>> controller;
    StreamSubscription<List<int>>? sub;
    var done = false;
    controller = StreamController<List<int>>(
      sync: true,
      onListen: () => sub = guarded.listen(
        controller.add,
        onError: controller.addError,
        onDone: () {
          done = true;
          controller.close();
        },
      ),
      onPause: () => sub?.pause(),
      onResume: () => sub?.resume(),
      onCancel: () {
        if (!done && !token.isCancelled) token.cancel('body cancelled');
        return sub?.cancel();
      },
    );
    return controller.stream;
  }

  static NetworkException _mapDioException(DioException e, Uri uri) =>
      switch (e.type) {
        DioExceptionType.cancel => NetworkException(
          NetworkErrorKind.cancelled,
          uri: uri,
          cause: e,
        ),
        DioExceptionType.connectionTimeout ||
        DioExceptionType.sendTimeout ||
        DioExceptionType.receiveTimeout => NetworkException(
          NetworkErrorKind.timeout,
          message: e.message,
          uri: uri,
          cause: e,
        ),
        _ => NetworkException(
          NetworkErrorKind.connection,
          message: '${e.error ?? e.message}',
          uri: uri,
          cause: e,
        ),
      };

  static bool _isRedirect(int status) =>
      status == 301 ||
      status == 302 ||
      status == 303 ||
      status == 307 ||
      status == 308;

  /// 解析 URL（相对地址基于 [base] 或 baseUrl）并做白名单检查。
  Uri _checkedUri(String url, {Uri? base}) {
    final Uri uri;
    try {
      uri = (base ?? config.baseUrl).resolve(url.trim());
    } on FormatException catch (e) {
      throw NetworkException(
        NetworkErrorKind.invalidRequest,
        message: 'invalid URL: $url',
        cause: e,
      );
    }
    if (!config.hostPolicy.isAllowed(uri)) {
      throw NetworkException(
        NetworkErrorKind.hostNotAllowed,
        message: 'host not allowed: ${uri.host}',
        uri: uri,
      );
    }
    return uri;
  }

  Future<_RawResponse> _sendWithRetry(
    String method,
    Uri uri,
    Map<String, String> headers,
    List<int>? body,
    Duration timeout,
    NetCancellation? cancellation,
  ) async {
    final retryable = _idempotent.contains(method);
    for (var attempt = 0; ; attempt++) {
      _throwIfCancelled(cancellation, uri);
      if (_bucket case final bucket?) {
        // 排队等待期间被取消时立即失败，且不消耗令牌。
        final acquired = await bucket.acquire(
          abort: cancellation?.whenCancelled,
        );
        if (!acquired) {
          throw NetworkException(NetworkErrorKind.cancelled, uri: uri);
        }
      }
      _throwIfCancelled(cancellation, uri);

      final canRetry = retryable && attempt < config.maxRetries;
      _RawResponse raw;
      try {
        raw = await _attempt(method, uri, headers, body, timeout, cancellation);
      } on NetworkException catch (e) {
        if (canRetry && e.kind == NetworkErrorKind.connection) {
          await _backoff(attempt);
          continue;
        }
        rethrow;
      }

      if (config.challengeDetector.isChallenge(
        raw.status,
        raw.headers,
        raw.bytes,
      )) {
        session.lastChallengeUrl = uri;
        throw NetworkException(
          NetworkErrorKind.challenge,
          message: 'human verification required',
          uri: uri,
          status: raw.status,
        );
      }
      if (canRetry && raw.status >= 500 && raw.status < 600) {
        await _backoff(attempt);
        continue;
      }
      return raw;
    }
  }

  Future<void> _backoff(int attempt) =>
      Future.delayed(config.retryBaseDelay * math.pow(2, attempt).toInt());

  void _throwIfCancelled(NetCancellation? c, Uri uri) {
    if (c != null && c.isCancelled) {
      throw NetworkException(NetworkErrorKind.cancelled, uri: uri);
    }
  }

  /// 单次尝试：总时长受 [timeout] 限制（含读取响应体），可被 [cancellation] 中断。
  Future<_RawResponse> _attempt(
    String method,
    Uri uri,
    Map<String, String> headers,
    List<int>? body,
    Duration timeout,
    NetCancellation? cancellation,
  ) {
    final token = CancelToken();
    final abort = Completer<_RawResponse>();
    void fail(NetworkException e) {
      if (abort.isCompleted) return;
      abort.completeError(e);
      token.cancel(e.kind.name);
    }

    final timer = Timer(
      timeout,
      () => fail(
        NetworkException(
          NetworkErrorKind.timeout,
          message: 'timed out after ${timeout.inMilliseconds} ms',
          uri: uri,
        ),
      ),
    );
    cancellation?.whenCancelled.then(
      (_) => fail(NetworkException(NetworkErrorKind.cancelled, uri: uri)),
    );

    final work = _send(method, uri, headers, body, token);
    // 先完成者胜出；另一方之后的结果 / 错误由 Future.any 吞掉。
    return Future.any([work, abort.future]).whenComplete(timer.cancel);
  }

  Future<_RawResponse> _send(
    String method,
    Uri uri,
    Map<String, String> headers,
    List<int>? body,
    CancelToken token,
  ) async {
    try {
      final response = await _dio.requestUri<ResponseBody>(
        uri,
        data: body == null ? null : Stream<List<int>>.value(body),
        cancelToken: token,
        options: Options(
          method: method,
          headers: {...headers, 'content-length': ?body?.length.toString()},
          followRedirects: false,
          validateStatus: (_) => true,
          responseType: ResponseType.stream,
        ),
      );
      final status = response.statusCode ?? 0;
      // HEAD / 1xx / 204 / 304 没有响应体，Content-Length 只是资源大小，不做预检。
      final bodyless =
          method == 'HEAD' ||
          (status >= 100 && status < 200) ||
          status == 204 ||
          status == 304;
      final bytes = await _readLimited(
        response.data!,
        uri,
        token,
        checkDeclaredLength: !bodyless,
      );
      return _RawResponse(status, response.headers.map, bytes);
    } on DioException catch (e) {
      throw _mapDioException(e, uri);
    }
  }

  Future<Uint8List> _readLimited(
    ResponseBody body,
    Uri uri,
    CancelToken token, {
    required bool checkDeclaredLength,
  }) async {
    final limit = config.maxResponseBytes;
    NetworkException tooLarge() => NetworkException(
      NetworkErrorKind.responseTooLarge,
      message: 'response body exceeds $limit bytes',
      uri: uri,
    );
    if (checkDeclaredLength && body.contentLength > limit) {
      token.cancel('too large');
      throw tooLarge();
    }
    final builder = BytesBuilder(copy: false);
    try {
      await for (final chunk in body.stream) {
        builder.add(chunk);
        if (builder.length > limit) {
          token.cancel('too large');
          throw tooLarge();
        }
      }
    } on NetworkException {
      rethrow;
    } catch (e) {
      if (e is DioException) rethrow;
      throw NetworkException(
        NetworkErrorKind.connection,
        message: 'error while reading body: $e',
        uri: uri,
        cause: e,
      );
    }
    return builder.takeBytes();
  }
}

class _RawStream {
  _RawStream(this.status, this.headers, this.body, this.token);

  final int status;

  /// 名称为小写（dio 的 `Headers.map` 已规范化）。
  final Map<String, List<String>> headers;
  final Stream<List<int>> body;
  final CancelToken token;

  _RawStream withBody(Stream<List<int>> body) =>
      _RawStream(status, headers, body, token);

  /// 中止请求，释放连接。
  void cancel() {
    if (!token.isCancelled) token.cancel('released');
  }
}

class _RawResponse {
  _RawResponse(this.status, this.headers, this.bytes);

  final int status;

  /// 名称为小写（dio 的 `Headers.map` 已规范化）。
  final Map<String, List<String>> headers;
  final Uint8List bytes;
}
