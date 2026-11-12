import 'dart:async';
import 'dart:convert';

import '../../core/engine/script/host/tsumugi_api.dart';
import '../../core/engine/script/isolate_script_runtime.dart';
import '../../core/engine/script/script_runtime.dart';
import '../../core/network/source_http_client.dart';
import '../../core/storage/source_storage.dart';
import '../model/common.dart';
import '../model/content.dart';
import '../model/manifest.dart';
import '../source.dart';
import 'script_host.dart';
import 'script_ui.dart';

export 'script_host.dart' show ScriptHostLimits;
export 'script_ui.dart';

/// `engine: "script"` 的 [Source] 实现（docs/source-spec.md §4）。
///
/// 脚本在独立 worker isolate 中的 QuickJS 沙箱里执行（[IsolateScriptRuntime]）；
/// `tsumugi.http / storage / cookies / ui / log` 在主 isolate 执行（[ScriptHost]），
/// `crypto / html` 在 worker 内同步执行。入口调用串行执行。
///
/// 结果用 `lib/sources/model/` 的模型解析，`content` 按清单 `type` 分派。
/// 结果中的相对地址（封面、图片、流、字幕）基于 `baseUrl` 解析为绝对地址，
/// 清单 `headers` 合并到 `coverHeaders` 与图片 / 流的 `headers`（结果中的同名项优先）。
/// 不再使用时调用 [dispose]（同时关闭 [http]）。
class ScriptSource implements Source {
  ScriptSource._(this.manifest, this._host, this._runtime);

  /// 创建并加载脚本源。清单不合法、脚本缺失或加载失败时抛出
  /// [SourceErrorCode.parse] 的 [SourceException]。
  ///
  /// [settings] 为用户设置值，未设置的键取清单中的默认值。
  static Future<ScriptSource> create({
    required SourceManifest manifest,
    required SourceHttpClient http,
    required SourceStorage storage,
    ScriptUi ui = const UnavailableScriptUi(),
    Map<String, Object?> settings = const {},
    void Function(String message)? log,
    ScriptLimits limits = const ScriptLimits(),
    ScriptHostLimits hostLimits = const ScriptHostLimits(),
    Duration hangGrace = const Duration(seconds: 5),
  }) async {
    if (manifest.engine != SourceEngine.script) {
      throw const SourceException(
        SourceErrorCode.unsupported,
        'engine 不是 script',
      );
    }
    final errors = manifest.validate();
    if (errors.isNotEmpty) {
      throw SourceException(SourceErrorCode.parse, errors.join('; '));
    }
    final script = manifest.script!;
    if (_looksLikePath(script)) {
      throw const SourceException(
        SourceErrorCode.unsupported,
        '尚不支持以相对路径引用脚本，请把脚本内联到清单的 script 字段',
      );
    }

    final logger = log ?? (_) {};
    final host = ScriptHost(
      manifest: manifest,
      http: http,
      storage: storage,
      ui: ui,
      log: logger,
      limits: hostLimits,
    );
    final runtime = IsolateScriptRuntime(
      host: host.functions,
      notifications: notificationPaths,
      workerHost: tsumugiWorkerHost,
      workerHostConfig: {'baseUrl': manifest.baseUrl},
      prelude: buildTsumugiPrelude({
        'id': manifest.id,
        'baseUrl': manifest.baseUrl,
        'settings': {
          for (final s in manifest.settings)
            s.key: _jsonSafe(settings[s.key] ?? s.defaultValue),
        },
      }),
      limits: limits,
      hangGrace: hangGrace,
      log: (m) => logger('[${manifest.id}] $m'),
    );
    final source = ScriptSource._(manifest, host, runtime);
    try {
      await runtime.load(script, name: '${manifest.id}.js');
    } on ScriptException catch (e) {
      source.dispose();
      // 保留引擎 / 脚本给出的错误码（如模块初始化超限 → E_LIMIT），其余为 E_PARSE。
      final mapped = _toSourceException(e);
      throw SourceException(
        mapped.code,
        '脚本加载失败: ${mapped.message}',
        mapped.status,
      );
    } on Object catch (e) {
      source.dispose();
      throw SourceException(SourceErrorCode.parse, '脚本加载失败: $e');
    }
    return source;
  }

  @override
  final SourceManifest manifest;
  final ScriptHost _host;
  final IsolateScriptRuntime _runtime;
  Future<void> _tail = Future.value();
  bool _disposed = false;

  SourceHttpClient get http => _host.http;

  /// worker 被重建的次数（诊断与测试用）。
  int get workerRestarts => _runtime.restarts;

  Uri get _base => http.config.baseUrl;

  @override
  Future<PageResult<SearchItem>> search(String keyword, int page) => _run(
    'search',
    [keyword, page],
    (v) => PageResult.fromJson(_map(v), (j) => SearchItem.fromJson(_item(j))),
  );

  @override
  Future<List<ExploreCategory>> explore() => _run('explore', const [], (v) {
    if (v is! List) throw const FormatException('explore() 应返回数组');
    return [
      for (final c in v)
        ExploreCategory.fromJson({
          ..._map(c),
          if (_map(c)['id'] case final num id) 'id': '$id',
        }),
    ];
  });

  @override
  Future<PageResult<SearchItem>> exploreList(String categoryId, int page) =>
      _run(
        'exploreList',
        [categoryId, page],
        (v) =>
            PageResult.fromJson(_map(v), (j) => SearchItem.fromJson(_item(j))),
      );

  @override
  Future<Detail> detail(String id) =>
      _run('detail', [id], (v) => Detail.fromJson(_detail(_map(v))));

  @override
  Future<MediaContent> content(String unitId) => _run('content', [
    unitId,
  ], (v) => MediaContent.fromJson(manifest.type, _content(_map(v))));

  /// 调用任意导出（测试与规则调试用），错误同样映射为 [SourceException]。
  Future<Object?> debugCall(String export, [List<Object?> args = const []]) =>
      _run(export, args, (v) => v);

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _runtime.dispose();
    http.close();
  }

  // ---------------------------------------------------------------------------

  /// 串行执行入口调用，每次调用一个 [ScriptCallScope]（请求计数、取消）。
  Future<T> _run<T>(
    String export,
    List<Object?> args,
    T Function(Object? value) convert,
  ) {
    final result = _tail.then((_) async {
      if (_disposed) {
        throw const SourceException(SourceErrorCode.unsupported, '源已释放');
      }
      final scope = _host.begin();
      final Object? value;
      try {
        value = await _runtime.call(export, args);
      } on ScriptException catch (e) {
        throw _toSourceException(e);
      } on StateError catch (e) {
        throw SourceException(SourceErrorCode.parse, e.message);
      } finally {
        scope.close();
      }
      try {
        return convert(value);
      } on SourceException {
        rethrow;
      } on Object catch (e) {
        throw SourceException(SourceErrorCode.parse, '$export() 的返回值无效: $e');
      }
    });
    _tail = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  static SourceException _toSourceException(ScriptException e) {
    final code = e.code == null ? null : SourceErrorCode.fromWire(e.code!);
    // 未捕获的普通 JS 异常、未知错误码：视为脚本未能解析出结果。
    return SourceException(
      code ?? SourceErrorCode.parse,
      code == null && e.code != null ? '${e.code}: ${e.message}' : e.message,
      code == SourceErrorCode.http ? e.status : null,
    );
  }

  // --- 结果规范化 -------------------------------------------------------------

  static Map<String, dynamic> _map(Object? v) {
    if (v is Map<String, dynamic>) return v;
    if (v is Map) return v.cast<String, dynamic>();
    throw FormatException('应返回对象，实际为 ${v.runtimeType}');
  }

  Map<String, dynamic> _item(Object? j) {
    final m = Map<String, dynamic>.of(_map(j));
    if (m['cover'] case final String cover) {
      m['cover'] = _abs(cover);
      m['coverHeaders'] = _mergeHeaders(m['coverHeaders']);
    }
    return m;
  }

  Map<String, dynamic> _detail(Map<String, dynamic> j) {
    final m = Map<String, dynamic>.of(j);
    if (m['cover'] case final String cover) m['cover'] = _abs(cover);
    m['units'] ??= const [];
    return m;
  }

  Map<String, dynamic> _content(Map<String, dynamic> j) {
    final m = Map<String, dynamic>.of(j);
    Object? refs(Object? list, {bool headers = true}) => list is List
        ? [
            for (final r in list)
              switch (r) {
                String() => {
                  'url': _abs(r),
                  if (headers) 'headers': _mergeHeaders(null),
                },
                Map() => {
                  ...r.cast<String, dynamic>(),
                  if (r['url'] case final String u) 'url': _abs(u),
                  if (headers) 'headers': _mergeHeaders(r['headers']),
                },
                // 非法元素不能被静默丢弃（source-spec §4.1：不符合结构 → E_PARSE）。
                _ => throw FormatException('无效的条目: ${jsonEncode(r)}'),
              },
          ]
        : list;
    switch (manifest.type) {
      case MediaType.comic:
        m['images'] = refs(m['images']);
      case MediaType.video:
        m['streams'] = refs(m['streams']);
        m['subtitles'] = refs(m['subtitles'], headers: false);
      case MediaType.music:
        m['streams'] = refs(m['streams']);
      case MediaType.novel:
    }
    m.removeWhere((_, v) => v == null);
    return m;
  }

  String _abs(String url) {
    final u = Uri.tryParse(url.trim());
    return u == null ? url : _base.resolveUri(u).toString();
  }

  Map<String, String>? _mergeHeaders(Object? own) {
    final merged = <String, String>{
      ...manifest.headers,
      if (own is Map)
        for (final e in own.entries)
          if (e.value != null) '${e.key}': '${e.value}',
    };
    return merged.isEmpty ? null : merged;
  }

  static bool _looksLikePath(String script) {
    final s = script.trim();
    return !s.contains('\n') &&
        s.endsWith('.js') &&
        !s.contains(' ') &&
        !s.contains('(');
  }

  static Object? _jsonSafe(Object? v) => switch (v) {
    null || bool() || num() || String() => v,
    final List l => [for (final e in l) _jsonSafe(e)],
    final Map m => {for (final e in m.entries) '${e.key}': _jsonSafe(e.value)},
    _ => '$v',
  };
}
