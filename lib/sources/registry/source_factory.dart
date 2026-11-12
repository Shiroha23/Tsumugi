import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../model/common.dart';
import '../model/manifest.dart';
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

/// 引擎实现在此注册各自的 [SourceFactory]（M1 声明式 / 脚本源会话负责）。
@Riverpod(keepAlive: true)
SourceFactories sourceFactories(Ref ref) => SourceFactories(const []);
