import '../../core/engine/declarative/declarative_engine.dart';
import '../../core/engine/declarative/fetcher.dart';
import '../../core/engine/declarative/rules.dart';
import '../../core/engine/expression/expression_engine.dart';
import '../../core/engine/expression/js_evaluator.dart';
import '../../core/engine/script/script_runtime.dart';
import '../../core/network/host_policy.dart';
import '../model/common.dart';
import '../model/content.dart';
import '../model/manifest.dart';
import '../source.dart';

/// `engine: "declarative"` 的 [Source] 实现：把 [DeclarativeEngine] 产出的 JSON
/// 转成 `lib/sources/model/` 中的模型，并把引擎错误映射为 [SourceException]。
///
/// 规则中用到 `js:` 时，所有片段在同一个 [ScriptRuntime] 沙箱中执行
/// （由 [scriptRuntimeFactory] 创建，首次用到时才加载）。不再使用时调用 [dispose]。
class DeclarativeSource implements Source {
  DeclarativeSource._(this.manifest, this._engine, this._js);

  /// 创建声明式源。清单不合法或规则结构错误时抛出
  /// [SourceErrorCode.parse] 的 [SourceException]。
  ///
  /// [settings] 为用户设置值，未设置的键取清单中的默认值。
  factory DeclarativeSource({
    required SourceManifest manifest,
    required Fetcher fetcher,
    ScriptRuntimeFactory? scriptRuntimeFactory,
    Map<String, Object?> settings = const {},
    DebugLog? log,
  }) {
    if (manifest.engine != SourceEngine.declarative) {
      throw const SourceException(
        SourceErrorCode.unsupported,
        'engine 不是 declarative',
      );
    }
    final errors = manifest.validate();
    if (errors.isNotEmpty) {
      throw SourceException(SourceErrorCode.parse, errors.join('; '));
    }

    final DeclarativeRules rules;
    try {
      rules = DeclarativeRules.fromJson(manifest.rules!);
    } on FormatException catch (e) {
      throw SourceException(SourceErrorCode.parse, e.message);
    }

    final logger = log ?? (_) {};
    final probe = ExpressionEngine(log: logger);
    final snippets = {
      for (final source in rules.expressions)
        ...?probe.parse(source)?.jsSnippets,
    };
    final js = snippets.isEmpty || scriptRuntimeFactory == null
        ? null
        : ScriptJsEvaluator(scriptRuntimeFactory, snippets);
    if (snippets.isNotEmpty && js == null) {
      logger('规则包含 js: 步骤，但未提供脚本运行时，这些步骤将求值为空');
    }

    final baseUrl = Uri.parse(manifest.baseUrl);
    final engine = DeclarativeEngine(
      baseUrl: baseUrl,
      mediaType: manifest.type.name,
      rules: rules,
      fetcher: fetcher,
      expressions: ExpressionEngine(js: js, log: logger),
      headers: manifest.headers,
      settings: {
        for (final s in manifest.settings)
          if ((settings[s.key] ?? s.defaultValue) case final v?) s.key: '$v',
      },
      hostPolicy: HostPolicy(
        baseUrl: baseUrl,
        allowedHosts: manifest.allowedHosts,
      ),
      log: logger,
    );
    return DeclarativeSource._(manifest, engine, js);
  }

  @override
  final SourceManifest manifest;
  final DeclarativeEngine _engine;
  final ScriptJsEvaluator? _js;

  @override
  Future<PageResult<SearchItem>> search(String keyword, int page) => _guard(
    () async => PageResult.fromJson(
      await _engine.search(keyword, page),
      SearchItem.fromJson,
    ),
  );

  @override
  Future<List<ExploreCategory>> explore() => _guard(
    () async => [
      for (final c in _engine.explore()) ExploreCategory.fromJson(c),
    ],
  );

  @override
  Future<PageResult<SearchItem>> exploreList(String categoryId, int page) =>
      _guard(
        () async => PageResult.fromJson(
          await _engine.exploreList(categoryId, page),
          SearchItem.fromJson,
        ),
      );

  @override
  Future<Detail> detail(String id) =>
      _guard(() async => Detail.fromJson(await _engine.detail(id)));

  @override
  Future<MediaContent> content(String unitId) => _guard(
    () async =>
        MediaContent.fromJson(manifest.type, await _engine.content(unitId)),
  );

  /// 释放 `js:` 使用的脚本运行时。
  void dispose() => _js?.dispose();

  static Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on DeclarativeException catch (e) {
      throw SourceException(
        SourceErrorCode.fromWire(e.code) ?? SourceErrorCode.network,
        e.message,
        e.status,
      );
    } on SourceException {
      rethrow;
    } on Object catch (e) {
      // 模型转换失败等。
      throw SourceException(SourceErrorCode.parse, '$e');
    }
  }
}
