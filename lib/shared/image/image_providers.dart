import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../core/network/source_http_client.dart';
import '../../sources/model/manifest.dart';
import '../../sources/registry/providers.dart';
import '../../sources/session/source_sessions.dart';
import '../../sources/source.dart';
import 'image_cache.dart';
import 'source_image_loader.dart';

part 'image_providers.g.dart';

/// 图片请求使用的按源 HTTP 客户端。
///
/// 默认实现按已安装源的清单为每个源构造一个独立的客户端（白名单、限速、默认 headers 与清单一致），
/// 但与源实例**共用该源的 `SourceSession`**（Cookie 与 WebView 同步的 UA，architecture §5.3），
/// 因此需要登录 / 验证 Cookie 的图片也能加载。限速队列不共用。
abstract interface class ImageHttpClients {
  Future<SourceHttpClient> clientFor(String sourceId);
}

/// 从源注册表读取清单构造客户端，按 sourceId 缓存。
class RegistryImageHttpClients implements ImageHttpClients {
  /// 订阅注册表的变化（直接订阅数据库流，不经 provider，避免无监听者时被 Riverpod 暂停），
  /// 源升级 / 重装 / 删除后丢弃旧客户端。
  ///
  /// [clientFor] 由清单构造客户端，默认不共用会话；应用中传入 `SourceSessions.clientFor`。
  RegistryImageHttpClients(
    this._registry, {
    SourceHttpClient Function(SourceManifest manifest)? clientFor,
  }) : _clientFor = clientFor ?? SourceSessions().clientFor {
    _changes = _registry.watchAll().listen(sync, onError: (Object _) {});
  }

  final SourceRegistry _registry;
  final SourceHttpClient Function(SourceManifest manifest) _clientFor;
  late final StreamSubscription<List<InstalledSource>> _changes;
  final _clients = <String, Future<SourceHttpClient>>{};

  /// 构造客户端时所用清单的 sha256，用于发现源升级 / 重装。
  final _manifestSha = <String, String>{};

  @override
  Future<SourceHttpClient> clientFor(String sourceId) {
    if (_clients[sourceId] case final existing?) return existing;
    final created = _create(sourceId);
    _clients[sourceId] = created;
    created.then(
      (_) {},
      onError: (Object _) {
        // 失败（源不存在 / 清单损坏）不缓存，下次重新查找。
        if (identical(_clients[sourceId], created)) _clients.remove(sourceId);
      },
    );
    return created;
  }

  Future<SourceHttpClient> _create(String sourceId) async {
    final installed = await _registry.get(sourceId);
    final manifest = installed?.manifest;
    if (installed == null || manifest == null) {
      throw SourceException(
        SourceErrorCode.unsupported,
        installed == null ? '源未安装：$sourceId' : '源清单不可用：$sourceId',
      );
    }
    _manifestSha[sourceId] = installed.manifestSha256;
    return _clientFor(manifest);
  }

  /// 已安装源列表变化时调用：清单变化（升级 / 重装）或被删除的源丢弃旧客户端，
  /// 下次加载按新清单（白名单、headers、限速）重建。
  void sync(Iterable<InstalledSource> installed) {
    final current = {for (final s in installed) s.id: s.manifestSha256};
    for (final id in _clients.keys.toList()) {
      final sha = _manifestSha[id];
      // sha 为 null：客户端仍在创建中，创建时读取的已是最新清单。
      if (sha != null && current[id] != sha) invalidate(id);
    }
  }

  /// 丢弃某个源的客户端。旧客户端稍后关闭，让进行中的请求有机会完成。
  void invalidate(String sourceId) {
    _manifestSha.remove(sourceId);
    final old = _clients.remove(sourceId);
    if (old == null) return;
    old
        .then((c) => Timer(closeDelay, c.close))
        .then<void>((_) {}, onError: (Object _) {});
  }

  /// [invalidate] 后旧客户端的关闭延迟。
  Duration closeDelay = const Duration(seconds: 30);

  void dispose() {
    _changes.cancel().ignore();
    for (final c in _clients.values) {
      c.then((c) => c.close()).ignore();
    }
    _clients.clear();
  }
}

@Riverpod(keepAlive: true)
ImageHttpClients imageHttpClients(Ref ref) {
  final clients = RegistryImageHttpClients(
    ref.watch(sourceRegistryProvider),
    clientFor: ref.watch(sourceSessionsProvider).clientFor,
  );
  ref.onDispose(clients.dispose);
  return clients;
}

/// 图片磁盘缓存：应用缓存目录下的 `images/`，默认上限 512 MB。
@Riverpod(keepAlive: true)
DiskImageCache diskImageCache(Ref ref) => FileDiskImageCache(
  () async => Directory(
    '${(await getApplicationCacheDirectory()).path}${Platform.pathSeparator}images',
  ),
);

/// 全局图片加载器（内存 64 MB + 磁盘缓存）。
@Riverpod(keepAlive: true)
SourceImageLoader sourceImageLoader(Ref ref) {
  final clients = ref.watch(imageHttpClientsProvider);
  return SourceImageLoader(
    httpClientFor: clients.clientFor,
    diskCache: ref.watch(diskImageCacheProvider),
  );
}
