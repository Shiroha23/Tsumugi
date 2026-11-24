import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/media/hls_playlist.dart' show HlsSubtitleRendition;
import '../../core/network/media/media_proxy.dart';
import '../../core/network/network_exception.dart';
import '../../core/network/source_http_client.dart';
import '../../sources/model/content.dart';
import '../download/download_library.dart' show DownloadedVideo;
import '../../sources/model/manifest.dart';
import '../../sources/registry/providers.dart';
import '../../sources/session/source_sessions.dart';
import '../../sources/source.dart';
import 'player_options.dart';

export '../../core/network/media/hls_playlist.dart' show HlsSubtitleRendition;

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
  ProxiedStream._(this._session, this._client) : _local = null;

  ProxiedStream._local(LocalMediaSession session)
    : _local = session,
      _session = null,
      _client = null;

  final MediaProxySession? _session;
  final SourceHttpClient? _client;
  final LocalMediaSession? _local;

  Uri get url => _session?.url ?? _local!.url;

  /// 本地来源（已下载的剧集）。
  bool get isLocal => _local != null;

  /// HLS 主播放列表声明的字幕轨（不交给播放器，由字幕层经本会话自己取，architecture §6.4.7）。
  /// 在线播放时播放器取过主播放列表之后才有（播放开始后读取）。
  List<HlsSubtitleRendition> get subtitleTracks =>
      _session?.subtitleTracks ?? _local!.subtitleTracks;

  /// 本地来源：曾有文件缺失或内容无法识别（下载已损坏）。
  bool get localFileError => _local?.hadFileError ?? false;

  /// 代理最近一次上游请求失败的原因（见 [MediaProxySession.lastFailure]）；本地来源为 null。
  NetworkException? get lastFailure => _session?.lastFailure;

  void close() {
    _session?.close();
    _client?.close();
    _local?.close();
  }
}

/// 为已下载的剧集建立本地来源的代理会话（architecture §4.5.1「离线回放」）：播放器看到的仍是
/// `http://127.0.0.1:<port>/<token>/…`，代理只按编号返回 [video] 登记的文件，不发上游请求。
final openLocalVideoProvider =
    Provider<Future<ProxiedStream> Function(DownloadedVideo video)>(
      (ref) => (video) async {
        final proxy = await ref.read(mediaProxyProvider.future);
        final layout = video.layout;
        final session = proxy.openLocal(
          root: layout.root,
          playlists: layout.playlists,
          files: {
            for (final MapEntry(key: name, value: (subtitle, ext))
                in layout.files.entries)
              name: LocalMediaFile(
                video.fileOf(name),
                subtitle ? LocalMediaKind.subtitle : LocalMediaKind.media,
                extension: ext,
              ),
          },
        );
        return ProxiedStream._local(session);
      },
    );

/// 代理请求上游所用的客户端：使用该源 `SourceSession`（Cookie、UA）的新客户端。
/// 集成测试覆盖它，把请求接到 mock 服务器。
final mediaProxyClientProvider =
    Provider<SourceHttpClient Function(SourceManifest manifest)>(
      (ref) => ref.read(sourceSessionsProvider).clientFor,
    );

/// 为某个源的 [stream] 建立代理会话。
///
/// 每次播放新建一个使用该源 `SourceSession`（Cookie、UA、令牌桶）的客户端，因此白名单、默认 headers
/// 与 Cookie 都与源实例一致，并与源实例、图片加载共用限速令牌桶（分片走本源的媒体配额，
/// source-spec §5）；`StreamRef.headers` 随每个请求发送。
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
        final client = ref.read(mediaProxyClientProvider)(manifest);
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
