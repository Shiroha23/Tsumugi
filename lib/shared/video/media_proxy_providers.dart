import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/media/media_proxy.dart';
import '../../core/network/network_exception.dart';
import '../../core/network/source_http_client.dart';
import '../../sources/model/content.dart';
import '../../sources/registry/providers.dart';
import '../../sources/session/source_sessions.dart';
import '../../sources/source.dart';
import 'player_options.dart';

/// 全局本地媒体代理（architecture §6.4），第一次播放时在 127.0.0.1 的随机端口上启动。
final mediaProxyProvider = FutureProvider<MediaProxy>((ref) async {
  // 失败原因总是输出；逐个请求的记录只在详细日志开启时输出（见 videoVerboseLogs）。
  // debugPrint 在 release 构建的 Android 上同样进入 logcat。
  final proxy = await MediaProxy.start(
    log: (m) => debugPrint('[media_proxy] $m'),
    trace: videoVerboseLogs ? (m) => debugPrint('[media_proxy] $m') : null,
  );
  ref.onDispose(proxy.close);
  return proxy;
});

/// 一次播放：播放器使用 [url]（代理地址），结束时 [close]。
class ProxiedStream {
  ProxiedStream._(this._session, this._client);

  final MediaProxySession _session;
  final SourceHttpClient _client;

  Uri get url => _session.url;

  /// 代理最近一次上游请求失败的原因（见 [MediaProxySession.lastFailure]）。
  NetworkException? get lastFailure => _session.lastFailure;

  void close() {
    _session.close();
    _client.close();
  }
}

/// 为某个源的 [stream] 建立代理会话。
///
/// 每次播放新建一个使用该源 `SourceSession`（Cookie、UA）的客户端，因此白名单、默认 headers、
/// Cookie 与限速都与源实例一致；`StreamRef.headers` 随每个请求发送。
final openProxiedStreamProvider =
    Provider<Future<ProxiedStream> Function(String sourceId, StreamRef stream)>(
      (ref) => (sourceId, stream) async {
        final installed = await ref.read(sourceRegistryProvider).get(sourceId);
        final manifest = installed?.manifest;
        if (installed == null || manifest == null) {
          throw SourceException(
            SourceErrorCode.unsupported,
            installed == null ? '源未安装：$sourceId' : '源清单不可用：$sourceId',
          );
        }
        final Uri url;
        try {
          url = Uri.parse(manifest.baseUrl).resolve(stream.url.trim());
        } on FormatException {
          throw SourceException(SourceErrorCode.parse, '无效的视频地址');
        }
        final proxy = await ref.read(mediaProxyProvider.future);
        final client = ref.read(sourceSessionsProvider).clientFor(manifest);
        try {
          final session = proxy.open(
            client: client,
            url: url,
            headers: stream.headers ?? const {},
          );
          return ProxiedStream._(session, client);
        } catch (_) {
          client.close();
          rethrow;
        }
      },
    );
