import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../core/network/dio_source_http_client.dart';
import '../../core/network/source_http_client.dart';
import '../../sources/network_error_mapping.dart';
import '../../sources/registry/providers.dart';
import '../../sources/source.dart';
import 'image_cache.dart';
import 'source_image_loader.dart';

part 'image_providers.g.dart';

/// 图片请求使用的按源 HTTP 客户端。
///
/// 默认实现按已安装源的清单为每个源构造一个独立的 [DioSourceHttpClient]（白名单、限速、
/// 默认 headers 与清单一致）。它与源实例自身的客户端**不共享** Cookie 域；
/// 需要登录 Cookie 的图片在集成阶段可覆盖此 provider，改为复用源的客户端。
abstract interface class ImageHttpClients {
  Future<SourceHttpClient> clientFor(String sourceId);
}

/// 从源注册表读取清单构造客户端，按 sourceId 缓存。
class RegistryImageHttpClients implements ImageHttpClients {
  RegistryImageHttpClients(this._registry);

  final SourceRegistry _registry;
  final _clients = <String, Future<SourceHttpClient>>{};

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
    if (manifest == null) {
      throw SourceException(
        SourceErrorCode.unsupported,
        installed == null ? '源未安装：$sourceId' : '源清单不可用：$sourceId',
      );
    }
    return DioSourceHttpClient(networkConfigFromManifest(manifest));
  }

  /// 丢弃某个源的客户端（例如源被升级或删除后）。
  void invalidate(String sourceId) {
    _clients.remove(sourceId)?.then((c) => c.close()).ignore();
  }

  void dispose() {
    for (final c in _clients.values) {
      c.then((c) => c.close()).ignore();
    }
    _clients.clear();
  }
}

@Riverpod(keepAlive: true)
ImageHttpClients imageHttpClients(Ref ref) {
  final clients = RegistryImageHttpClients(ref.watch(sourceRegistryProvider));
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
