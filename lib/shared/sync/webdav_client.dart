import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'sync_exception.dart';

/// 远端数据文件名（architecture §4.6）。
const syncFileName = 'sync-v1.json';

/// 默认远端目录。
const defaultRemoteDir = 'Tsumugi/';

/// 远端文件（压缩后）与解压后的上限。
const maxSyncFileBytes = 20 * 1024 * 1024;

/// 校验并规范化服务器地址：只允许 `https`，回环地址（`127.0.0.1` / `localhost` / `::1`）可用 `http`；
/// 不允许在地址里带用户名 / 密码、查询或片段。返回的地址路径以 `/` 结尾。
Uri parseServerUrl(String input) {
  final text = input.trim();
  final uri = Uri.tryParse(text);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    throw const SyncException(SyncError.invalidConfig, '服务器地址无效');
  }
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'https' && !(scheme == 'http' && isLoopbackHost(uri.host))) {
    throw const SyncException(
      SyncError.invalidConfig,
      '只支持 https 地址（本机回环地址除外）',
    );
  }
  if (uri.userInfo.isNotEmpty) {
    throw const SyncException(SyncError.invalidConfig, '地址中不能包含用户名或密码，请分别填写');
  }
  if (uri.hasQuery || uri.hasFragment) {
    throw const SyncException(SyncError.invalidConfig, '地址中不能包含 ? 或 #');
  }
  final path = uri.path.endsWith('/') ? uri.path : '${uri.path}/';
  return uri.replace(scheme: scheme, path: path);
}

/// 测试用回环地址。
bool isLoopbackHost(String host) {
  final h = host.toLowerCase();
  return h == 'localhost' || h == '127.0.0.1' || h == '::1' || h == '[::1]';
}

/// 规范化远端目录：去掉首尾与重复的 `/`，拒绝 `.` / `..` 段与反斜杠；空字符串表示服务器地址本身。
/// 返回的各段未经编码。
List<String> parseRemoteDir(String input) {
  final segments = input.trim().split('/').where((s) => s.isNotEmpty).toList();
  for (final s in segments) {
    if (s == '.' || s == '..' || s.contains('\\') || s.trim() != s) {
      throw const SyncException(SyncError.invalidConfig, '远端目录无效');
    }
  }
  return segments;
}

/// 把规范化后的目录写回设置中显示的形式（`a/b/`，空目录为空串）。
String formatRemoteDir(List<String> segments) =>
    segments.isEmpty ? '' : '${segments.join('/')}/';

/// 一个 WebDAV 服务器上的同步位置与凭据。
final class WebDavConfig {
  WebDavConfig({
    required String serverUrl,
    required this.username,
    required this.password,
    String remoteDir = defaultRemoteDir,
  }) : server = parseServerUrl(serverUrl),
       dirSegments = parseRemoteDir(remoteDir);

  final Uri server;
  final List<String> dirSegments;
  final String username;
  final String password;

  /// [dirSegments] 前 [count] 段对应的目录地址（以 `/` 结尾）。
  Uri dirUri([int? count]) {
    final segs = dirSegments.take(count ?? dirSegments.length);
    final path = StringBuffer(server.path);
    for (final s in segs) {
      path
        ..write(Uri.encodeComponent(s))
        ..write('/');
    }
    return server.replace(path: path.toString());
  }

  Uri get fileUri => dirUri().replace(path: '${dirUri().path}$syncFileName');
}

/// [WebDavClient.get] 的结果。
sealed class WebDavGetResult {
  const WebDavGetResult();
}

/// 文件内容与 ETag（服务器不返回时为 null）。
final class WebDavFile extends WebDavGetResult {
  const WebDavFile(this.bytes, this.etag);

  final Uint8List bytes;
  final String? etag;
}

/// 带 `If-None-Match` 请求时远端未变（304）。
final class WebDavNotModified extends WebDavGetResult {
  const WebDavNotModified();
}

/// 远端还没有文件（404）。
final class WebDavNotFound extends WebDavGetResult {
  const WebDavNotFound();
}

/// `PUT` 的前置条件不成立（412）：期间有别的设备写入。
class WebDavPreconditionFailed implements Exception {
  const WebDavPreconditionFailed();
}

/// 只实现同步需要的 `PROPFIND` / `MKCOL` / `GET` / `PUT`（architecture §4.6）。
///
/// 独立的 dio 实例：无 Cookie、固定 UA、不跟随重定向（凭据不会被带到别的地址）、不接受传输压缩（ETag 不被改写）。
/// 每个请求（含读响应体）总时长不超过 [requestTimeout]，超时取消请求。
class WebDavClient {
  WebDavClient(
    this.config, {
    HttpClientAdapter? adapter,
    this.requestTimeout = defaultRequestTimeout,
  }) : _dio = Dio(
         BaseOptions(
           connectTimeout: requestTimeout,
           sendTimeout: requestTimeout,
           receiveTimeout: requestTimeout,
           followRedirects: false,
           validateStatus: (_) => true,
           responseType: ResponseType.stream,
           headers: {
             'User-Agent': 'Tsumugi-Sync/1',
             'Accept-Encoding': 'identity',
           },
         ),
       ) {
    if (adapter != null) _dio.httpClientAdapter = adapter;
  }

  static const defaultRequestTimeout = Duration(seconds: 60);

  /// 错误响应、304 / 404 等只读这么多字节就丢弃。
  static const _drainLimit = 64 * 1024;

  final WebDavConfig config;
  final Duration requestTimeout;
  final Dio _dio;

  String get _auth =>
      'Basic ${base64Encode(utf8.encode('${config.username}:${config.password}'))}';

  void close() => _dio.close(force: true);

  /// 发出请求并用 [handle] 处理响应（含读响应体），整体不超过 [requestTimeout]。
  Future<T> _call<T>(
    Uri uri,
    String method,
    Future<T> Function(Response<ResponseBody> res) handle, {
    Map<String, String> headers = const {},
    Object? data,
  }) async {
    final cancel = CancelToken();
    var timedOut = false;
    final timer = Timer(requestTimeout, () {
      timedOut = true;
      cancel.cancel('timeout');
    });
    try {
      final Response<ResponseBody> res;
      try {
        res = await _dio.requestUri<ResponseBody>(
          uri,
          data: data,
          cancelToken: cancel,
          options: Options(
            method: method,
            headers: {'Authorization': _auth, ...headers},
          ),
        );
      } on DioException catch (e) {
        throw _networkError(e, timedOut);
      }
      try {
        final result = await handle(res);
        // 丢弃响应体时被取消也算超时（_drain 吞掉了取消错误）。
        if (timedOut) {
          throw const SyncException(SyncError.network, '连接服务器超时');
        }
        return result;
      } on SyncException {
        rethrow;
      } on WebDavPreconditionFailed {
        rethrow;
      } catch (e) {
        if (timedOut) {
          throw const SyncException(SyncError.network, '连接服务器超时');
        }
        throw SyncException(SyncError.network, '读取服务器响应失败：$e');
      }
    } finally {
      timer.cancel();
    }
  }

  static SyncException _networkError(DioException e, bool timedOut) {
    if (timedOut) return const SyncException(SyncError.network, '连接服务器超时');
    return switch (e.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout => const SyncException(
        SyncError.network,
        '连接服务器超时',
      ),
      DioExceptionType.badCertificate => const SyncException(
        SyncError.network,
        '服务器证书无效',
      ),
      _ => SyncException(SyncError.network, '无法连接服务器：${e.message ?? e.error}'),
    };
  }

  /// 读完响应体（不超过 [limit] 字节）。
  Future<Uint8List> _readBody(Response<ResponseBody> res, int limit) async {
    final body = res.data;
    if (body == null) return Uint8List(0);
    final out = BytesBuilder(copy: false);
    await for (final chunk in body.stream) {
      out.add(chunk);
      if (out.length > limit) {
        throw const SyncException(SyncError.tooLarge, '远端同步文件超过 20 MiB');
      }
    }
    return out.takeBytes();
  }

  /// 丢弃响应体：最多读 [_drainLimit] 字节，超过即停止（取消订阅）。
  Future<void> _drain(Response<ResponseBody> res) async {
    final stream = res.data?.stream;
    if (stream == null) return;
    var n = 0;
    try {
      await for (final chunk in stream) {
        n += chunk.length;
        if (n > _drainLimit) break;
      }
    } catch (_) {}
  }

  /// 把非预期的状态码转为错误（已丢弃响应体）。
  Future<Never> _fail(Response<ResponseBody> res, String action) async {
    await _drain(res);
    final code = res.statusCode ?? 0;
    throw switch (code) {
      401 || 403 => const SyncException(SyncError.auth, '用户名或密码错误，或没有访问该目录的权限'),
      >= 300 && < 400 => const SyncException(
        SyncError.server,
        '服务器返回了重定向，请填写最终的 WebDAV 地址',
      ),
      507 => const SyncException(SyncError.server, '服务器空间不足'),
      _ => SyncException(SyncError.server, '$action失败（HTTP $code）'),
    };
  }

  /// 下载数据文件；[ifNoneMatch] 为上次的 ETag。
  Future<WebDavGetResult> get({String? ifNoneMatch}) => _call(
    config.fileUri,
    'GET',
    headers: {'If-None-Match': ?ifNoneMatch},
    (res) async {
      switch (res.statusCode) {
        case 200:
          final bytes = await _readBody(res, maxSyncFileBytes);
          return WebDavFile(bytes, _etag(res));
        case 304 when ifNoneMatch != null:
          await _drain(res);
          return const WebDavNotModified();
        case 404:
          await _drain(res);
          return const WebDavNotFound();
      }
      return _fail(res, '下载同步文件');
    },
  );

  /// 上传数据文件，返回新的 ETag（服务器不返回时为 null）。
  ///
  /// [ifMatch] 非 null 时带 `If-Match`；[createOnly] 为 true 时带 `If-None-Match: *`（远端还没有文件）。
  /// 412 抛出 [WebDavPreconditionFailed]；409（父目录不存在）时先创建目录再重试一次。
  Future<String?> put(
    Uint8List bytes, {
    String? ifMatch,
    bool createOnly = false,
  }) async {
    for (var attempt = 0; ; attempt++) {
      final (:retry, :etag) = await _call<({bool retry, String? etag})>(
        config.fileUri,
        'PUT',
        headers: {
          'Content-Type': 'application/octet-stream',
          // 明确长度：部分服务器 / 反向代理不接受 chunked 上传（411）。
          'Content-Length': '${bytes.length}',
          'If-Match': ?ifMatch,
          if (createOnly) 'If-None-Match': '*',
        },
        data: bytes,
        (res) async {
          switch (res.statusCode) {
            case 200 || 201 || 204:
              await _drain(res);
              return (retry: false, etag: _etag(res));
            case 412:
              await _drain(res);
              throw const WebDavPreconditionFailed();
            case 409 when attempt == 0:
              await _drain(res);
              return (retry: true, etag: null);
          }
          return _fail(res, '上传同步文件');
        },
      );
      if (!retry) return etag;
      await ensureDirectory();
    }
  }

  /// 目录是否存在（`PROPFIND`，Depth: 0）。
  Future<bool> exists(Uri dir) => _call(
    dir,
    'PROPFIND',
    headers: {'Depth': '0', 'Content-Type': 'application/xml; charset=utf-8'},
    data: _propfindBody,
    (res) async {
      switch (res.statusCode) {
        case 207 || 200:
          await _drain(res);
          return true;
        case 404:
          await _drain(res);
          return false;
      }
      return _fail(res, '读取远端目录');
    },
  );

  /// 逐级创建远端目录（已存在的跳过）。
  Future<void> ensureDirectory() async {
    for (var i = 1; i <= config.dirSegments.length; i++) {
      final dir = config.dirUri(i);
      if (await exists(dir)) continue;
      await _call(dir, 'MKCOL', (res) async {
        switch (res.statusCode) {
          // 405：已存在（并发创建）。
          case 201 || 200 || 204 || 405:
            await _drain(res);
            return;
        }
        await _fail(res, '创建远端目录');
      });
    }
  }

  /// 测试连接：服务器地址可访问且凭据有效。
  Future<void> checkConnection() async {
    if (!await exists(config.dirUri(0))) {
      throw const SyncException(SyncError.server, '服务器地址不存在（HTTP 404）');
    }
  }

  /// 强 ETag；没有或为弱 ETag（`W/` 开头，不能用于 `If-Match`）时为 null，按“不支持条件请求”处理。
  static String? _etag(Response<ResponseBody> res) {
    final v = res.headers.value('etag')?.trim();
    if (v == null || v.isEmpty || v.startsWith('W/')) return null;
    return v;
  }

  static const _propfindBody =
      '<?xml version="1.0" encoding="utf-8"?>'
      '<propfind xmlns="DAV:"><prop><resourcetype/></prop></propfind>';
}
