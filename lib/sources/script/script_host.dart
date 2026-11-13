import 'dart:async';
import 'dart:convert';

import '../../core/encoding/text_decoding.dart';
import '../../core/engine/script/script_runtime.dart';
import '../../core/network/network_exception.dart';
import '../../core/network/source_http_client.dart';
import '../../core/storage/source_storage.dart';
import '../model/manifest.dart';
import '../network_error_mapping.dart';
import '../source.dart';
import 'script_ui.dart';

/// 脚本宿主 API 中由主 isolate 执行的部分的限制（docs/source-spec.md §4.4）。
class ScriptHostLimits {
  const ScriptHostLimits({
    this.maxRequestsPerCall = 50,
    this.maxStorageKeyLength = 256,
    this.maxStorageValueChars = 1 << 20,
    this.maxStorageCharsPerSource = 10 << 20,
    this.maxLogChars = 4000,
    this.maxWebViewsPerCall = 1,
    this.maxDonePatternLength = 512,
  });

  /// 单次入口调用最多发出的 `tsumugi.http.*` 请求数（重试与重定向不另计）。
  final int maxRequestsPerCall;
  final int maxStorageKeyLength;

  /// 单个值 JSON 编码后的最大长度（码点，下同）。
  final int maxStorageValueChars;

  /// 单个源全部键值的总长度上限。
  final int maxStorageCharsPerSource;

  /// 单条日志的最大长度，超出截断。
  final int maxLogChars;

  /// 单次入口调用最多调用 `ui.openWebView` 的次数（超出 → `E_LIMIT`）。
  /// 跨调用的频率限制由 UI 实现负责（architecture §5.3）。
  final int maxWebViewsPerCall;

  /// `doneWhenUrlMatches` 正则的最大长度。
  final int maxDonePatternLength;
}

/// 一次入口调用的上下文：请求计数与取消信号。
class ScriptCallScope {
  int requests = 0;
  int webViews = 0;
  final cancellation = NetCancellation();
  bool _closed = false;

  bool get isClosed => _closed;

  void close() {
    _closed = true;
    cancellation.cancel();
  }
}

/// 构造主 isolate 一侧的宿主函数（`tsumugi.http / storage / cookies / ui / log`）。
///
/// 所有错误都以 [ScriptException] 抛出，`code` / `status` 按 source-spec §6；
/// 宿主函数只能在 [begin] 与 [ScriptCallScope.close] 之间使用。
class ScriptHost {
  ScriptHost({
    required this.manifest,
    required this.http,
    required this.storage,
    required this.ui,
    required this.log,
    this.limits = const ScriptHostLimits(),
  });

  final SourceManifest manifest;
  final SourceHttpClient http;
  final SourceStorage storage;
  final ScriptUi ui;
  final ScriptHostLimits limits;
  final void Function(String message) log;

  ScriptCallScope? _scope;

  String get _id => manifest.id;

  /// 开始一次入口调用；调用结束后调用方必须 [ScriptCallScope.close]。
  ScriptCallScope begin() {
    _scope?.close();
    return _scope = ScriptCallScope();
  }

  ScriptCallScope _active() {
    final scope = _scope;
    if (scope == null || scope.isClosed) {
      throw const ScriptException('No active call for host function.');
    }
    return scope;
  }

  Map<String, HostFunction> get functions => {
    'http.request': (a) => _guard(() => _request(a)),
    'http.get': (a) => _guard(() async {
      final r = await _send(
        _net(_str(a, 0, 'url'), headers: _headers(_arg(a, 1), 'headers')),
      );
      return r.text;
    }),
    'http.getJson': (a) => _guard(() async {
      final r = await _send(
        _net(_str(a, 0, 'url'), headers: _headers(_arg(a, 1), 'headers')),
      );
      return r.json();
    }),
    'storage.get': (a) => _guard(() async {
      _active();
      final raw = await storage.read(_id, _key(a));
      return raw == null ? null : jsonDecode(raw);
    }),
    'storage.set': (a) => _guard(() {
      // 在收到请求时绑定调用：调用结束后才轮到的写操作被丢弃，不会落到下一次调用上。
      final scope = _active();
      return _storageSet(scope, _key(a), _arg(a, 1));
    }),
    'storage.remove': (a) => _guard(() async {
      final scope = _active();
      final done = await storage.delete(
        _id,
        _key(a),
        isCancelled: () => scope.isClosed,
      );
      if (!done) throw _callEnded;
      return null;
    }),
    'cookies.get': (a) => _guard(() async {
      _active();
      return http.getCookies(_str(a, 0, 'url'));
    }),
    'cookies.set': (a) => _guard(() async {
      _active();
      final name = _str(a, 1, 'name');
      if (name.isEmpty || name.contains(RegExp(r'[\s;=,]'))) {
        throw ScriptException('Invalid cookie name "$name".');
      }
      final value = _str(a, 2, 'value');
      if (value.contains(RegExp(r'[;\r\n]'))) {
        throw const ScriptException('Invalid cookie value.');
      }
      await http.setCookie(_str(a, 0, 'url'), name, value);
      return null;
    }),
    'ui.openWebView': (a) => _guard(() async {
      final scope = _active();
      final url = http.config.baseUrl.resolve(_str(a, 0, 'url'));
      if (!http.config.hostPolicy.isAllowed(url)) {
        throw const SourceException(
          SourceErrorCode.hostNotAllowed,
          'openWebView: host not allowed',
        );
      }
      final opts = _arg(a, 1);
      if (opts != null && opts is! Map) {
        throw const ScriptException('openWebView options must be an object.');
      }
      final pattern = (opts as Map?)?['doneWhenUrlMatches'];
      final title = opts?['title'];
      if (pattern != null) {
        if (pattern is! String) {
          throw const ScriptException('doneWhenUrlMatches must be a string.');
        }
        if (pattern.length > limits.maxDonePatternLength) {
          throw ScriptException(
            'doneWhenUrlMatches is longer than ${limits.maxDonePatternLength} characters.',
          );
        }
        try {
          RegExp(pattern);
        } on FormatException catch (e) {
          throw ScriptException('Invalid doneWhenUrlMatches: ${e.message}');
        }
      }
      if (scope.webViews >= limits.maxWebViewsPerCall) {
        throw ScriptException(
          'ui.openWebView may be called at most ${limits.maxWebViewsPerCall} '
          'time(s) per call.',
          code: ScriptException.limit,
        );
      }
      scope.webViews++;
      await ui.openWebView(
        WebViewRequest(
          sourceId: _id,
          url: url,
          cookies: http,
          title: title is String ? title : null,
          doneWhenUrlMatches: pattern as String?,
        ),
      );
      return null;
    }),
    // 以下为发出即忘：返回值与异常都被忽略。
    'ui.toast': (a) {
      ui.toast(_id, _clip(_join(a)));
      return null;
    },
    'log.debug': (a) => _emit('debug', a),
    'log.info': (a) => _emit('info', a),
    'log.error': (a) => _emit('error', a),
  };

  // --- http -------------------------------------------------------------------

  static const _methods = {'GET', 'POST', 'PUT', 'DELETE', 'HEAD'};

  Future<Object?> _request(List<Object?> a) async {
    final opts = _arg(a, 0);
    if (opts is! Map) {
      throw const ScriptException('http.request options must be an object.');
    }
    final url = opts['url'];
    if (url is! String) throw const ScriptException('"url" must be a string.');
    final method = switch (opts['method']) {
      null => 'GET',
      final String m when _methods.contains(m.toUpperCase()) => m.toUpperCase(),
      final m => throw ScriptException('Unsupported method "$m".'),
    };
    final body = opts['body'];
    final form = opts['form'];
    if (body != null && form != null) {
      throw const ScriptException('Use either "body" or "form", not both.');
    }
    final NetBody? netBody = switch ((body, form)) {
      (null, null) => null,
      (final String s, _) => NetBody.text(s),
      (final Map m, _) => NetBody.json(m),
      (final List l, _) => NetBody.json(l),
      (null, final Map f) => NetBody.form({
        for (final e in f.entries) '${e.key}': '${e.value ?? ''}',
      }),
      _ => throw const ScriptException('Invalid "body" / "form".'),
    };
    final responseType = opts['responseType'] ?? 'text';
    if (!const {'text', 'json', 'bytes'}.contains(responseType)) {
      throw ScriptException('Unsupported responseType "$responseType".');
    }
    final charset = opts['charset'];
    if (charset != null &&
        (charset is! String || normalizeCharset(charset) == null)) {
      throw ScriptException('Unsupported charset "$charset".');
    }
    final follow = opts['followRedirects'] ?? true;
    if (follow is! bool) {
      throw const ScriptException('"followRedirects" must be a boolean.');
    }
    final r = await _send(
      _net(
        url,
        method: method,
        headers: _headers(opts['headers'], 'headers'),
        body: netBody,
        followRedirects: follow,
        throwOnHttpError: false,
      ),
    );
    return {
      'status': r.status,
      'headers': r.headers,
      'url': r.url.toString(),
      'body': switch (responseType) {
        'json' => r.bytes.isEmpty ? null : r.json(charset: charset as String?),
        'bytes' => base64.encode(r.bytes),
        _ => r.decodeText(charset: charset as String?),
      },
    };
  }

  NetRequest _net(
    String url, {
    String method = 'GET',
    Map<String, String> headers = const {},
    NetBody? body,
    bool followRedirects = true,
    bool throwOnHttpError = true,
  }) {
    final scope = _active();
    if (scope.requests >= limits.maxRequestsPerCall) {
      throw ScriptException(
        'More than ${limits.maxRequestsPerCall} HTTP requests in one call.',
        code: ScriptException.limit,
      );
    }
    scope.requests++;
    return NetRequest(
      url,
      method: method,
      headers: headers,
      body: body,
      followRedirects: followRedirects,
      throwOnHttpError: throwOnHttpError,
      cancellation: scope.cancellation,
    );
  }

  Future<NetResponse> _send(NetRequest request) => http.request(request);

  // --- storage ----------------------------------------------------------------

  String _key(List<Object?> a) {
    final key = _str(a, 0, 'key');
    if (key.contains(' ')) {
      throw const ScriptException('Storage key must not contain NUL.');
    }
    if (key.isEmpty || codePoints(key) > limits.maxStorageKeyLength) {
      throw ScriptException(
        'Storage key must be 1–${limits.maxStorageKeyLength} characters.',
      );
    }
    return key;
  }

  static const _callEnded = ScriptException(
    'No active call for host function.',
  );

  Future<Object?> _storageSet(
    ScriptCallScope scope,
    String key,
    Object? value,
  ) async {
    bool cancelled() => scope.isClosed;
    if (value == null) {
      if (!await storage.delete(_id, key, isCancelled: cancelled)) {
        throw _callEnded;
      }
      return null;
    }
    final json = jsonEncode(value);
    if (codePoints(json) > limits.maxStorageValueChars) {
      throw ScriptException(
        'Storage value too large (max ${limits.maxStorageValueChars} chars).',
        code: ScriptException.limit,
      );
    }
    final written = await storage.write(
      _id,
      key,
      json,
      quota: limits.maxStorageCharsPerSource,
      isCancelled: cancelled,
    );
    if (written) return null;
    if (scope.isClosed) throw _callEnded;
    throw ScriptException(
      'Storage quota exceeded (max ${limits.maxStorageCharsPerSource} chars per source).',
      code: ScriptException.limit,
    );
  }

  // --- log --------------------------------------------------------------------

  Object? _emit(String level, List<Object?> a) {
    log('[$_id] $level: ${_clip(_join(a))}');
    return null;
  }

  String _join(List<Object?> a) =>
      a.map((v) => v is String ? v : jsonEncode(v)).join(' ');

  String _clip(String s) => s.length <= limits.maxLogChars
      ? s
      : '${s.substring(0, limits.maxLogChars)}…';

  // --- 参数与错误 -------------------------------------------------------------

  static Object? _arg(List<Object?> a, int i) => i < a.length ? a[i] : null;

  static String _str(List<Object?> a, int i, String name) {
    final v = _arg(a, i);
    if (v is! String) throw ScriptException('"$name" must be a string.');
    return v;
  }

  static Map<String, String> _headers(Object? v, String name) => switch (v) {
    null => const {},
    final Map m => {
      for (final e in m.entries)
        if (e.value != null) '${e.key}': '${e.value}',
    },
    _ => throw ScriptException('"$name" must be an object.'),
  };

  /// 把宿主侧错误统一成带 §6 错误码的 [ScriptException]。
  static Future<Object?> _guard(FutureOr<Object?> Function() body) async {
    try {
      return await body();
    } on ScriptException {
      rethrow;
    } on NetworkException catch (e) {
      final s = e.toSourceException();
      throw ScriptException(
        s.message ?? s.code.wire,
        code: s.code.wire,
        status: s.status,
      );
    } on SourceException catch (e) {
      throw ScriptException(
        e.message ?? e.code.wire,
        code: e.code.wire,
        status: e.status,
      );
    } on FormatException catch (e) {
      throw ScriptException(e.message, code: SourceErrorCode.parse.wire);
    }
  }
}
