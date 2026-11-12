import 'dart:async';

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../core/network/dio_source_http_client.dart';
import '../../core/network/source_http_client.dart';
import '../../core/network/source_session.dart';
import '../model/manifest.dart';
import '../network_error_mapping.dart';
import '../registry/providers.dart';

part 'source_sessions.g.dart';

/// 按 sourceId 提供 [SourceSession]（docs/architecture.md §5.3）。
///
/// 同一源的源实例客户端与图片客户端都从这里取会话，从而共用 Cookie 与 UA；
/// 不同源的会话相互独立。会话只在内存中（重启后需重新验证）。
class SourceSessions {
  SourceSessions();

  /// 订阅 [registry]：源被删除后丢弃其会话（重新安装时从空会话开始）。
  SourceSessions.watching(SourceRegistry registry) {
    _changes = registry.watchAll().listen(
      (all) => retainOnly(all.map((s) => s.id)),
      onError: (Object _) {},
    );
  }

  final _sessions = <String, SourceSession>{};
  StreamSubscription<Object?>? _changes;

  SourceSession of(String sourceId) =>
      _sessions.putIfAbsent(sourceId, SourceSession.new);

  /// 已存在的会话；不存在时返回 null（不创建）。
  SourceSession? peek(String sourceId) => _sessions[sourceId];

  /// 丢弃不在 [installedIds] 中的会话。
  void retainOnly(Iterable<String> installedIds) {
    final keep = installedIds.toSet();
    _sessions.removeWhere((id, _) => !keep.contains(id));
  }

  void remove(String sourceId) => _sessions.remove(sourceId);

  /// 为 [manifest] 构造使用其会话的 HTTP 客户端。
  SourceHttpClient clientFor(SourceManifest manifest) => DioSourceHttpClient(
    networkConfigFromManifest(manifest),
    session: of(manifest.id),
  );

  void dispose() {
    _changes?.cancel().ignore();
    _sessions.clear();
  }
}

@Riverpod(keepAlive: true)
SourceSessions sourceSessions(Ref ref) {
  final sessions = SourceSessions.watching(ref.watch(sourceRegistryProvider));
  ref.onDispose(sessions.dispose);
  return sessions;
}
