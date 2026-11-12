import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../core/storage/app_database.dart';
import '../../core/storage/source_storage.dart';
import '../model/common.dart';
import '../declarative/declarative_source_factory.dart';
import '../model/manifest.dart';
import '../script/script_source_factory.dart';
import '../script/script_ui.dart';
import '../session/source_sessions.dart';
import '../source.dart';

part 'source_factory.g.dart';

/// 按引擎类型把清单构造成可运行的 [Source]。
///
/// 声明式引擎与脚本引擎各自实现一个，并注册到 [sourceFactoriesProvider]。
abstract interface class SourceFactory {
  /// 此工厂负责的引擎。
  SourceEngine get engine;

  /// [manifest] 已通过校验，且 `manifest.engine == engine`。
  Future<Source> create(SourceManifest manifest);
}

/// 已注册的工厂，按引擎索引。
final class SourceFactories {
  SourceFactories(Iterable<SourceFactory> factories)
    : _byEngine = {for (final f in factories) f.engine: f};

  final Map<SourceEngine, SourceFactory> _byEngine;

  bool supports(SourceEngine engine) => _byEngine.containsKey(engine);

  /// 没有对应引擎的工厂时抛出 [SourceErrorCode.unsupported]。
  Future<Source> create(SourceManifest manifest) {
    final factory = _byEngine[manifest.engine];
    if (factory == null) {
      throw SourceException(
        SourceErrorCode.unsupported,
        '尚未支持 ${manifest.engine.name} 引擎',
      );
    }
    return factory.create(manifest);
  }
}

/// 已注册的引擎工厂。创建出的源由调用方释放（见 `lib/sources/runtime/`）。
///
/// 两种引擎的 HTTP 客户端都使用该源的 [SourceSessions] 会话（与图片加载共用 Cookie / UA）。
@Riverpod(keepAlive: true)
SourceFactories sourceFactories(Ref ref) {
  final sessions = ref.watch(sourceSessionsProvider);
  return SourceFactories([
    DeclarativeSourceFactory(httpClientFor: sessions.clientFor),
    ScriptSourceFactory(
      storage: DriftSourceStorage(ref.watch(appDatabaseProvider)),
      httpClientFor: sessions.clientFor,
      ui: ref.watch(scriptUiProvider),
    ),
  ]);
}

/// 脚本宿主 API `tsumugi.ui` 的界面实现；界面层接入 WebView 后覆盖此 provider。
@Riverpod(keepAlive: true)
ScriptUi scriptUi(Ref ref) => const UnavailableScriptUi();
