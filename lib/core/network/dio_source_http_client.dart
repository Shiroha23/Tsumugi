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
    final headers = <String, String>{
      for (final e in config.defaultHeaders.entries)
        e.key.toLowerCase(): e.value,
      for (final e in request.headers.entries) e.key.toLowerCase(): e.value,
    };
    if (session.userAgent case final ua? when ua.isNotEmpty) {
      headers.putIfAbsent('user-agent', () => ua);
    }
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
        if (next.host != uri.host) {
          // 不把调用方显式设置的凭据带到其他主机；Jar 中的 Cookie 由 CookieManager 按域名附加。
          headers
            ..remove('authorization')
            ..remove('cookie');
        }
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
      throw switch (e.type) {
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

class _RawResponse {
  _RawResponse(this.status, this.headers, this.bytes);

  final int status;

  /// 名称为小写（dio 的 `Headers.map` 已规范化）。
  final Map<String, List<String>> headers;
  final Uint8List bytes;
}
