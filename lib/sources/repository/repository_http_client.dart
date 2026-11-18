import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'repository_exception.dart';

/// 规则仓库专用的 HTTP 客户端（docs/architecture.md §4.4）。
///
/// 与源的网络层完全独立：无 Cookie、不带任何源的 headers、固定 UA；只允许 `https`
/// （[allowLoopbackHttp] 为 true 时回环地址 `127.0.0.1` / `localhost` / `::1` 例外，仅供测试；应用中始终为 false）；重定向逐跳检查同样的规则，最多 [maxRedirects] 跳；
/// 一次获取（含全部重定向与读取响应体）不超过 [timeout]；响应体超过上限即中止。
class RepositoryHttpClient {
  /// [adapter] 仅用于测试（例如把连接接到本地 mock 服务器）。
  RepositoryHttpClient({
    HttpClientAdapter? adapter,
    this.timeout = const Duration(seconds: 15),
    this.maxRedirects = 5,
    this.allowLoopbackHttp = false,
  }) {
    // connectTimeout：总时限到期后连接阶段也会被放弃，不在后台挂到系统超时。
    _dio = Dio(BaseOptions(connectTimeout: timeout));
    if (adapter != null) _dio.httpClientAdapter = adapter;
  }

  /// 固定的客户端 UA，不随源变化。
  static const userAgent = 'Tsumugi-Repository/1';

  /// 索引大小上限（source-spec §7）。
  static const maxIndexBytes = 2 * 1024 * 1024;

  /// 清单大小上限（与本地文件导入相同）。
  static const maxManifestBytes = 4 * 1024 * 1024;

  final Duration timeout;
  final int maxRedirects;

  /// 是否允许回环地址上的 `http`（仅测试）。发布版中远程仓库因此不能把客户端引向本机服务。
  final bool allowLoopbackHttp;
  late final Dio _dio;

  /// 取 [url] 的原始字节，最多 [maxBytes] 字节。失败时抛出 [RepositoryException]。
  Future<RepositoryResponse> get(Uri url, {required int maxBytes}) async {
    checkRepositoryUri(url, allowLoopbackHttp: allowLoopbackHttp);
    final state = _FetchState();
    final abort = Completer<RepositoryResponse>();
    final timer = Timer(timeout, () {
      if (abort.isCompleted) return;
      abort.completeError(
        RepositoryException(
          RepositoryErrorKind.network,
          '请求超时（${timeout.inSeconds} 秒）：$url',
        ),
      );
      state.token.cancel('timeout');
    });
    final work = _follow(url, maxBytes, state);
    return await Future.any([work, abort.future]).whenComplete(timer.cancel);
  }

  Future<RepositoryResponse> _follow(
    Uri url,
    int maxBytes,
    _FetchState state,
  ) async {
    var uri = url;
    for (var hop = 0; ; hop++) {
      final token = state.token;
      final ResponseBody body;
      try {
        final response = await _dio.requestUri<ResponseBody>(
          uri,
          cancelToken: token,
          options: Options(
            method: 'GET',
            // 只发这些头：无 Cookie、无 Referer、无源的 headers。
            headers: {'user-agent': userAgent, 'accept': 'application/json'},
            followRedirects: false,
            validateStatus: (_) => true,
            responseType: ResponseType.stream,
          ),
        );
        body = response.data!;
      } on DioException catch (e) {
        throw _mapDio(e, uri);
      }
      final status = body.statusCode;
      if (_redirects.contains(status)) {
        // 重定向响应体不需要，直接丢弃。
        token.cancel('redirect');
        final location = body.headers['location']?.firstOrNull;
        if (location == null) {
          throw RepositoryException(
            RepositoryErrorKind.http,
            '重定向缺少 Location：$uri',
            status: status,
          );
        }
        if (hop >= maxRedirects) {
          throw RepositoryException(
            RepositoryErrorKind.tooManyRedirects,
            '重定向超过 $maxRedirects 次：$url',
          );
        }
        final Uri next;
        try {
          next = uri.resolve(location);
        } on FormatException {
          throw RepositoryException(
            RepositoryErrorKind.http,
            '重定向地址无效：$location',
            status: status,
          );
        }
        checkRepositoryUri(next, allowLoopbackHttp: allowLoopbackHttp);
        uri = next;
        state.token = CancelToken();
        continue;
      }
      if (status < 200 || status >= 300) {
        token.cancel('status');
        throw RepositoryException(
          RepositoryErrorKind.http,
          '服务器返回 HTTP $status：$uri',
          status: status,
        );
      }
      return RepositoryResponse(
        uri,
        await _readLimited(body, uri, maxBytes, token),
      );
    }
  }

  Future<Uint8List> _readLimited(
    ResponseBody body,
    Uri uri,
    int limit,
    CancelToken token,
  ) async {
    RepositoryException tooLarge() => RepositoryException(
      RepositoryErrorKind.tooLarge,
      '文件超过 ${limit ~/ 1024 ~/ 1024} MiB 上限：$uri',
    );
    if (body.contentLength > limit) {
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
    } on RepositoryException {
      rethrow;
    } on DioException catch (e) {
      throw _mapDio(e, uri);
    } catch (e) {
      throw RepositoryException(RepositoryErrorKind.network, '读取响应失败：$e');
    }
    return builder.takeBytes();
  }

  static RepositoryException _mapDio(DioException e, Uri uri) =>
      RepositoryException(
        RepositoryErrorKind.network,
        '无法连接：${uri.host}（${e.message ?? e.type.name}）',
      );

  void close() => _dio.close(force: true);

  static const _redirects = {301, 302, 303, 307, 308};
}

/// 一次获取的结果。
final class RepositoryResponse {
  const RepositoryResponse(this.url, this.bytes);

  /// 跟随重定向后的最终地址，仅供诊断。索引中的相对地址按订阅地址解析，不按它（source-spec §7）。
  final Uri url;
  final Uint8List bytes;
}

class _FetchState {
  /// 当前这一跳的取消令牌（超时时取消）。
  CancelToken token = CancelToken();
}

/// 回环地址：仅这些主机、且仅在测试中允许使用 `http`（source-spec §7）。
const _loopbackHosts = {'127.0.0.1', 'localhost', '::1'};

/// [uri] 是否可用于仓库索引 / 清单：`https`（[allowLoopbackHttp] 时另允许回环地址上的 `http`）；
/// 必须有主机，不允许用户信息。
bool isAllowedRepositoryUri(Uri uri, {bool allowLoopbackHttp = false}) {
  if (uri.host.isEmpty || uri.userInfo.isNotEmpty) return false;
  return switch (uri.scheme.toLowerCase()) {
    'https' => true,
    'http' =>
      allowLoopbackHttp && _loopbackHosts.contains(uri.host.toLowerCase()),
    _ => false,
  };
}

/// 不满足 [isAllowedRepositoryUri] 时抛出 [RepositoryException]。
void checkRepositoryUri(Uri uri, {bool allowLoopbackHttp = false}) {
  if (!isAllowedRepositoryUri(uri, allowLoopbackHttp: allowLoopbackHttp)) {
    throw RepositoryException(
      RepositoryErrorKind.insecureUrl,
      '只允许 https 地址：$uri',
    );
  }
}
