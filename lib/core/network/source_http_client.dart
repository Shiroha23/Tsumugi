import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'challenge_detector.dart';
import 'host_policy.dart';
import 'network_exception.dart';

/// 声明式引擎与脚本宿主 API（`tsumugi.http` / `tsumugi.cookies`）共用的按源 HTTP 客户端。
///
/// 每个实例只服务一个源：独立的 Cookie 域、默认 headers、超时、限速队列与白名单
/// （docs/source-spec.md §5）。所有方法均为异步；失败时抛出 [NetworkException]。
abstract interface class SourceHttpClient {
  SourceNetworkConfig get config;

  /// 发出请求。
  ///
  /// - 相对 URL 基于 `baseUrl` 解析；初始地址与每一跳重定向都经过 [HostPolicy] 检查。
  /// - 默认对任何状态码都返回响应；[NetRequest.throwOnHttpError] 为 true 时非 2xx 抛出
  ///   [NetworkErrorKind.http]。
  /// - 检测到人机验证页面时总是抛出 [NetworkErrorKind.challenge]。
  Future<NetResponse> request(NetRequest request);

  /// 读取本源 Cookie 域中会发往 [url] 的 Cookie（name → value）。[url] 必须在白名单内。
  Future<Map<String, String>> getCookies(String url);

  /// 为 [url] 写入一个 Cookie（如 WebView 验证完成后回写）。[url] 必须在白名单内。
  Future<void> setCookie(String url, String name, String value);

  /// 清空本源的全部 Cookie。
  Future<void> clearCookies();

  /// 释放底层连接；之后不可再使用。
  void close();
}

/// 便捷方法：成功（2xx）时返回文本 / JSON，否则抛出 [NetworkException]。
extension SourceHttpClientX on SourceHttpClient {
  Future<String> getText(String url, {Map<String, String>? headers}) async =>
      (await request(
        NetRequest(url, headers: headers ?? const {}, throwOnHttpError: true),
      )).text;

  Future<Object?> getJson(String url, {Map<String, String>? headers}) async =>
      (await request(
        NetRequest(url, headers: headers ?? const {}, throwOnHttpError: true),
      )).json();
}

/// 单个源的网络配置，通常由清单（docs/source-spec.md §1）生成，
/// 见 `lib/sources/network_error_mapping.dart` 的 `networkConfigFromManifest`。
class SourceNetworkConfig {
  SourceNetworkConfig({
    required this.sourceId,
    required this.baseUrl,
    Iterable<String> allowedHosts = const [],
    this.defaultHeaders = const {},
    this.timeout = const Duration(seconds: 15),
    this.rateLimit,
    this.maxRetries = 2,
    this.retryBaseDelay = const Duration(milliseconds: 300),
    this.maxRedirects = 5,
    this.maxResponseBytes = 20 * 1024 * 1024,
    this.challengeDetector = const ChallengeDetector(),
  }) : allowedHosts = List.unmodifiable(allowedHosts),
       hostPolicy = HostPolicy(baseUrl: baseUrl, allowedHosts: allowedHosts);

  final String sourceId;
  final Uri baseUrl;
  final List<String> allowedHosts;
  final HostPolicy hostPolicy;

  /// 每个请求都会带上的 headers（请求自带的同名 header 优先，名称不区分大小写）。
  final Map<String, String> defaultHeaders;

  /// 单次尝试（连接 + 等待响应 + 读取响应体）的超时；不含限速排队与重试间隔。
  final Duration timeout;

  /// null 表示不限速。
  final RateLimitConfig? rateLimit;

  /// 幂等请求（GET / HEAD / PUT / DELETE / OPTIONS）在连接错误或 5xx 时的最多重试次数。
  /// 超时不重试，以免总耗时成倍增长。
  final int maxRetries;

  /// 第 n 次重试前等待 `retryBaseDelay * 2^(n-1)`。
  final Duration retryBaseDelay;

  final int maxRedirects;

  /// 单个响应体上限（docs/source-spec.md §4.4，默认 20 MB），超出 → `E_LIMIT`。
  final int maxResponseBytes;

  final ChallengeDetector challengeDetector;
}

/// 每 [per] 时间内最多 [requests] 个请求（令牌桶，允许突发 [requests] 个）。
class RateLimitConfig {
  const RateLimitConfig({required this.requests, required this.per});

  final int requests;
  final Duration per;
}

/// 请求体。
sealed class NetBody {
  const NetBody();

  /// 原样发送的文本（默认 `text/plain; charset=utf-8`）。
  const factory NetBody.text(String text) = TextBody;

  /// 按 JSON 编码发送（`application/json; charset=utf-8`）。
  const factory NetBody.json(Object? value) = JsonBody;

  /// `application/x-www-form-urlencoded`。
  const factory NetBody.form(Map<String, String> fields) = FormBody;

  /// 原始字节（默认 `application/octet-stream`）。
  const factory NetBody.bytes(List<int> bytes) = BytesBody;

  String get defaultContentType;
  List<int> encode();
}

class TextBody extends NetBody {
  const TextBody(this.text);
  final String text;
  @override
  String get defaultContentType => 'text/plain; charset=utf-8';
  @override
  List<int> encode() => utf8.encode(text);
}

class JsonBody extends NetBody {
  const JsonBody(this.value);
  final Object? value;
  @override
  String get defaultContentType => 'application/json; charset=utf-8';
  @override
  List<int> encode() => utf8.encode(jsonEncode(value));
}

class FormBody extends NetBody {
  const FormBody(this.fields);
  final Map<String, String> fields;
  @override
  String get defaultContentType => 'application/x-www-form-urlencoded';
  @override
  List<int> encode() => utf8.encode(
    fields.entries
        .map(
          (e) =>
              '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
        )
        .join('&'),
  );
}

class BytesBody extends NetBody {
  const BytesBody(this.bytes);
  final List<int> bytes;
  @override
  String get defaultContentType => 'application/octet-stream';
  @override
  List<int> encode() => bytes;
}

/// 取消信号；可在多个请求间共享（例如一次脚本入口调用内的所有请求）。
class NetCancellation {
  final _completer = Completer<void>();

  bool get isCancelled => _completer.isCompleted;
  Future<void> get whenCancelled => _completer.future;

  void cancel() {
    if (!_completer.isCompleted) _completer.complete();
  }
}

class NetRequest {
  const NetRequest(
    this.url, {
    this.method = 'GET',
    this.headers = const {},
    this.body,
    this.followRedirects = true,
    this.throwOnHttpError = false,
    this.timeout,
    this.cancellation,
  });

  /// 绝对地址，或基于 `baseUrl` 的相对地址。
  final String url;

  /// GET | POST | PUT | DELETE | HEAD | PATCH | OPTIONS（不区分大小写）。
  final String method;
  final Map<String, String> headers;
  final NetBody? body;
  final bool followRedirects;

  /// true 时非 2xx（以及 `followRedirects == false` 时的非 3xx）抛出 [NetworkErrorKind.http]。
  final bool throwOnHttpError;

  /// 覆盖 [SourceNetworkConfig.timeout]。
  final Duration? timeout;
  final NetCancellation? cancellation;
}

class NetResponse {
  NetResponse({
    required this.status,
    required this.url,
    required this.headersAll,
    required this.bytes,
  });

  final int status;

  /// 最终地址（跟随重定向之后）。
  final Uri url;

  /// 响应头，名称为小写。
  final Map<String, List<String>> headersAll;
  final Uint8List bytes;

  bool get ok => status >= 200 && status < 300;

  /// 响应头，名称小写，多值以 `, ` 连接（与 source-spec §4.2 的 `Headers` 一致）。
  late final Map<String, String> headers = {
    for (final MapEntry(:key, :value) in headersAll.entries)
      key: value.join(', '),
  };

  String? header(String name) => headers[name.toLowerCase()];

  /// 按 `Content-Type` 的 charset 解码（支持 utf-8 / latin1 / ascii，其余按 utf-8 宽松解码）。
  late final String text = _decodeText();

  /// 把 [text] 解析为 JSON；失败抛出 [NetworkErrorKind.decode]。
  Object? json() {
    try {
      return jsonDecode(text);
    } on FormatException catch (e) {
      throw NetworkException(
        NetworkErrorKind.decode,
        message: 'invalid JSON: ${e.message}',
        uri: url,
        status: status,
        cause: e,
      );
    }
  }

  String _decodeText() {
    final charset = RegExp(
      r'charset="?([\w.:-]+)"?',
      caseSensitive: false,
    ).firstMatch(header('content-type') ?? '')?.group(1)?.toLowerCase();
    switch (charset) {
      case 'iso-8859-1' || 'latin1' || 'latin-1':
        return latin1.decode(bytes);
      case 'us-ascii' || 'ascii':
        return ascii.decode(bytes, allowInvalid: true);
      default:
        final s = utf8.decode(bytes, allowMalformed: true);
        return s.startsWith('﻿') ? s.substring(1) : s;
    }
  }
}
