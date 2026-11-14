import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../shared/video/media_proxy_providers.dart';
import '../../../shared/video/player_options.dart';
import '../../../shared/widgets/source_error_view.dart';
import '../../../sources/model/content.dart';
import '../../../sources/network_error_mapping.dart';
import '../../../sources/runtime/source_runtime.dart';
import '../../../sources/source.dart';

/// 最小视频播放页（M4 技术验证，architecture §6.4）：取 `content(unitId)` 的第一个流，
/// 经本地媒体代理交给 media_kit（libmpv）播放。播放 / 暂停 / 进度 / 全屏由 media_kit 的
/// 自适应控件提供，倍速在标题栏菜单中。
///
/// 播放器只拿到 `http://127.0.0.1:<port>/…` 的代理地址；上游请求全部由该源的网络层发出。
class VideoPlayerPage extends ConsumerStatefulWidget {
  const VideoPlayerPage({
    super.key,
    required this.sourceId,
    required this.itemId,
    required this.unitId,
    this.title,
  });

  final String sourceId;
  final String itemId;
  final String unitId;
  final String? title;

  @override
  ConsumerState<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

const _speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

class _VideoPlayerPageState extends ConsumerState<VideoPlayerPage> {
  late final Player _player = createVideoPlayer();
  late final VideoController _video = createVideoController(_player);
  final _subscriptions = <StreamSubscription<Object?>>[];
  ProxiedStream? _stream;
  Object? _error;
  String? _playerError;
  bool _loading = true;
  double _rate = 1;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _subscriptions.add(
      _player.stream.error.listen((e) {
        if (!mounted) return;
        // 代理记录的上游失败（白名单、人机验证、超时……）比播放器的错误文字更有用：
        // 人机验证 / 登录时显示「打开验证页」，完成后重新加载。
        final failure = _stream?.lastFailure;
        setState(() {
          if (failure != null) {
            _error = failure.toSourceException();
          } else {
            _playerError = e;
          }
        });
      }),
    );
    // 诊断日志（debugPrint：release 构建在 Android 上同样进入 logcat）。
    // libmpv 的警告 / 错误总是输出（播放器只上报这两级）；状态变化只在详细日志开启时输出。
    void log(String m) => debugPrint('[player] $m');
    _subscriptions.add(
      _player.stream.log.listen(
        (l) => log('mpv ${l.level} ${l.prefix}: ${l.text}'),
      ),
    );
    if (videoVerboseLogs) {
      var firstPosition = true;
      _subscriptions
        ..add(_player.stream.duration.listen((d) => log('duration $d')))
        ..add(_player.stream.buffering.listen((b) => log('buffering $b')))
        ..add(_player.stream.completed.listen((c) => log('completed $c')))
        ..add(
          _player.stream.position.listen((p) {
            if (firstPosition && p > Duration.zero) {
              firstPosition = false;
              log('first position $p');
            }
          }),
        );
    }
    _subscriptions.add(
      _player.stream.rate.listen((r) {
        if (mounted) setState(() => _rate = r);
      }),
    );
    _load();
  }

  /// 这次加载仍是最新的（没有被重试或页面销毁取代）。
  bool _current(int generation) => mounted && generation == _generation;

  Future<void> _load() async {
    final generation = ++_generation;
    _stream?.close();
    _stream = null;
    setState(() {
      _loading = true;
      _error = null;
      _playerError = null;
    });
    try {
      final source = await ref.read(
        sourceInstanceProvider(widget.sourceId).future,
      );
      final content = await source.content(widget.unitId);
      if (content is! VideoContent) {
        throw const SourceException(SourceErrorCode.parse, '内容不是视频');
      }
      final stream = content.streams
          .where((s) => s.type != StreamType.dash)
          .firstOrNull;
      if (stream == null) {
        throw SourceException(
          SourceErrorCode.unsupported,
          content.streams.isEmpty ? '没有可播放的流' : '暂不支持 DASH',
        );
      }
      final proxied = await ref.read(openProxiedStreamProvider)(
        widget.sourceId,
        stream,
      );
      if (!_current(generation)) {
        proxied.close();
        return;
      }
      _stream = proxied;
      await hardenVideoPlayer(_player);
      if (!_current(generation)) return;
      await openWhenVideoReady(
        _player,
        _video,
        proxied.url.toString(),
        stillCurrent: () => _current(generation),
        log: (m) => debugPrint('[player] $m'),
      );
      if (_current(generation)) setState(() => _loading = false);
      // 诊断：实际使用的解码路径（真机比较 hwdec 时看 logcat）。
      if (videoVerboseLogs) {
        Future<void>.delayed(const Duration(seconds: 1), () async {
          if (!_current(generation)) return;
          debugPrint('[player] decoder ${await describeVideoDecoder(_player)}');
        });
      }
    } on Object catch (e) {
      if (_current(generation)) {
        setState(() {
          _error = e;
          _loading = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _generation++; // 进行中的加载不再操作播放器
    for (final s in _subscriptions) {
      s.cancel().ignore();
    }
    _player.dispose().ignore();
    _stream?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title ?? '播放'),
        actions: [
          PopupMenuButton<double>(
            tooltip: '倍速',
            initialValue: _rate,
            onSelected: _player.setRate,
            itemBuilder: (_) => [
              for (final s in _speeds)
                PopupMenuItem(value: s, child: Text('${s}x')),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Center(child: Text('${_rate}x')),
            ),
          ),
        ],
      ),
      body: switch (_error) {
        final error? => Center(
          child: SourceErrorView(
            error: error,
            sourceId: widget.sourceId,
            onRetry: _load,
          ),
        ),
        null => Column(
          children: [
            Expanded(
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // 真正从头开始播放之前不显示控件：Android 上第一次打开 HLS 时进度会短暂停在别处
                  // （重新打开之前，见 openWhenVideoReady），用加载遮罩盖住画面与进度。
                  Video(
                    controller: _video,
                    controls: _loading
                        ? NoVideoControls
                        : AdaptiveVideoControls,
                  ),
                  if (_loading)
                    const Positioned.fill(
                      child: ColoredBox(
                        color: Colors.black,
                        child: Center(child: CircularProgressIndicator()),
                      ),
                    ),
                ],
              ),
            ),
            if (_playerError case final message?)
              Material(
                color: Theme.of(context).colorScheme.errorContainer,
                child: ListTile(
                  leading: const Icon(Icons.error_outline),
                  title: Text('播放出错：$message'),
                  trailing: TextButton(
                    onPressed: _load,
                    child: const Text('重试'),
                  ),
                ),
              ),
          ],
        ),
      },
    );
  }
}
