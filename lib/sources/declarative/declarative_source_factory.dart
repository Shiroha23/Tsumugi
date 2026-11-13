import 'dart:developer' as developer;

import '../../core/engine/declarative/fetcher.dart';
import '../../core/engine/script/isolate_script_runtime.dart';
import '../../core/engine/script/script_runtime.dart';
import '../../core/network/dio_source_http_client.dart';
import '../../core/network/network_exception.dart';
import '../../core/network/source_http_client.dart';
import '../model/common.dart';
import '../model/content.dart';
import '../model/manifest.dart';
import '../network_error_mapping.dart';
import '../registry/source_factory.dart';
import '../source.dart';
import 'declarative_source.dart';

/// 把按源的 [SourceHttpClient] 适配为声明式引擎的 [Fetcher]。
///
/// 非 2xx 响应原样返回（由引擎转换为 `E_HTTP`）；网络层错误转换为带 §6 错误码的
/// [FetchException]（例如 `E_CHALLENGE`、`E_HOST_NOT_ALLOWED`）。
class SourceHttpFetcher implements Fetcher {
  SourceHttpFetcher(this.http);

  final SourceHttpClient http;

  @override
  Future<FetchResponse> fetch(FetchRequest request) async {
    final NetResponse response;
    try {
      response = await http.request(
        NetRequest(
          request.url.toString(),
          method: request.method,
          headers: request.headers,
          body: request.body == null ? null : NetBody.text(request.body!),
        ),
      );
    } on NetworkException catch (e) {
      final mapped = e.toSourceException();
      throw FetchException(mapped.code.wire, mapped.message, mapped.status);
    }
    return FetchResponse(
      status: response.status,
      url: response.url,
      headers: response.headers,
      body: response.decodeText(charset: request.charset),
    );
  }
}

typedef DeclarativeHttpClientBuilder = SourceHttpClient Function(
  SourceManifest manifest,
);

SourceHttpClient _defaultHttp(SourceManifest manifest) =>
    DioSourceHttpClient(networkConfigFromManifest(manifest));

void _defaultLog(String message) =>
    developer.log(message, name: 'tsumugi.declarative');

/// `engine: "declarative"` 的 [SourceFactory]。
///
/// 创建的源是 [ManagedDeclarativeSource]，由调用方负责 `dispose`
/// （同时关闭其 HTTP 客户端与 `js:` 沙箱）。
class DeclarativeSourceFactory implements SourceFactory {
  DeclarativeSourceFactory({
    this.httpClientFor = _defaultHttp,
    this.scriptRuntimeFactory = IsolateScriptRuntime.create,
    this.log = _defaultLog,
  });

  final DeclarativeHttpClientBuilder httpClientFor;
  final ScriptRuntimeFactory? scriptRuntimeFactory;
  final void Function(String message) log;

  @override
  SourceEngine get engine => SourceEngine.declarative;

  @override
  Future<Source> create(SourceManifest manifest) async {
    final http = httpClientFor(manifest);
    try {
      final source = DeclarativeSource(
        manifest: manifest,
        fetcher: SourceHttpFetcher(http),
        scriptRuntimeFactory: scriptRuntimeFactory,
        log: (m) => log('[${manifest.id}] $m'),
      );
      return ManagedDeclarativeSource(source, http);
    } catch (_) {
      http.close();
      rethrow;
    }
  }
}

/// 持有自己 HTTP 客户端的 [DeclarativeSource]；[dispose] 时一并关闭。
class ManagedDeclarativeSource implements Source {
  ManagedDeclarativeSource(this._inner, this._http);

  final DeclarativeSource _inner;
  final SourceHttpClient _http;
  bool _disposed = false;

  @override
  SourceManifest get manifest => _inner.manifest;

  @override
  Future<PageResult<SearchItem>> search(String keyword, int page) =>
      _inner.search(keyword, page);

  @override
  Future<List<ExploreCategory>> explore() => _inner.explore();

  @override
  Future<PageResult<SearchItem>> exploreList(String categoryId, int page) =>
      _inner.exploreList(categoryId, page);

  @override
  Future<Detail> detail(String id) => _inner.detail(id);

  @override
  Future<MediaContent> content(String unitId) => _inner.content(unitId);

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _inner.dispose();
    _http.close();
  }
}
