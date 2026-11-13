import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:path_provider/path_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../core/network/dio_source_http_client.dart';
import '../../core/network/session_persistence.dart';
import '../../core/network/source_http_client.dart';
import '../../core/network/source_session.dart';
import '../model/manifest.dart';
import '../network_error_mapping.dart';
import '../registry/providers.dart';

part 'source_sessions.g.dart';

/// 按 sourceId 提供 [SourceSession]（docs/architecture.md §5.3）。
///
/// 同一源的源实例客户端与图片客户端都从这里取会话，从而共用 Cookie 与 UA；
/// 不同源的会话相互独立。给出 [persistence] 时会话按源持久化（§5.3「会话持久化」），
/// 否则只在内存中。
class SourceSessions {
  SourceSessions({this.persistence});

  /// 订阅 [registry]：源被删除后关闭其会话并删除持久化文件（重新安装时从空会话开始）；
  /// 第一次读到已安装源列表时清理不属于任何已安装源的会话文件。
  SourceSessions.watching(SourceRegistry registry, {this.persistence}) {
    _changes = registry.watchAll().listen(
      (all) => retainOnly(all.map((s) => s.id)),
      onError: (Object _) {},
    );
  }

  final SessionPersistence? persistence;
  final _sessions = <String, SourceSession>{};
  StreamSubscription<Object?>? _changes;

  /// 上一次 [retainOnly] 的已安装源；为 null 表示还没收到过。
  Set<String>? _installed;

  /// 第一次 [retainOnly] 触发的会话文件清理。
  @visibleForTesting
  Future<void>? initialSweep;

  SourceSession of(String sourceId) => _sessions.putIfAbsent(sourceId, () {
    final p = persistence;
    return p == null ? SourceSession() : SourceSession.persistent(sourceId, p);
  });

  /// 已存在的会话；不存在时返回 null（不创建）。
  SourceSession? peek(String sourceId) => _sessions[sourceId];

  /// 丢弃不在 [installedIds] 中的会话并删除其持久化文件。
  ///
  /// 第一次调用时清理目录中所有不属于 [installedIds] 的会话文件；之后只删除上次在、这次不在的源，
  /// 避免较早的列表在较晚安装的源写入后才执行清理。
  void retainOnly(Iterable<String> installedIds) {
    final keep = installedIds.toSet();
    final previous = _installed;
    _installed = keep;
    final removed = {
      ...?previous,
      ..._sessions.keys,
    }.where((id) => !keep.contains(id));
    for (final id in removed.toList()) {
      remove(id);
    }
    if (previous == null) {
      initialSweep = persistence?.sweep(
        () => {...?_installed, ..._sessions.keys},
      );
    }
  }

  /// 关闭并丢弃 [sourceId] 的会话，删除其持久化文件。
  void remove(String sourceId) {
    _sessions.remove(sourceId)?.close();
    persistence?.delete(sourceId).ignore();
  }

  /// 「清除 Cookie 与登录状态」：清空 [sourceId] 会话的 Cookie、UA 与挑战地址并删除持久化文件。
  Future<void> clear(String sourceId) => of(sourceId).clear();

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

/// 会话持久化目录：应用支持目录下的 `source_sessions/`（不放缓存目录，避免被系统清理）。
/// 为 null 时会话只在内存中（测试中覆盖为 null）。
@Riverpod(keepAlive: true)
SessionPersistence? sessionPersistence(Ref ref) => SessionPersistence(
  () async => Directory(
    '${(await getApplicationSupportDirectory()).path}'
    '${Platform.pathSeparator}source_sessions',
  ),
  log: (m) => debugPrint('[session] $m'),
);

@Riverpod(keepAlive: true)
SourceSessions sourceSessions(Ref ref) {
  final sessions = SourceSessions.watching(
    ref.watch(sourceRegistryProvider),
    persistence: ref.watch(sessionPersistenceProvider),
  );
  ref.onDispose(sessions.dispose);
  return sessions;
}
