import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../shared/history/providers.dart';
import '../../../shared/library/providers.dart';
import '../../../shared/video/media_proxy_providers.dart';
import '../../../shared/video/player_options.dart';
import '../../../shared/widgets/source_error_view.dart';
import '../../../sources/model/content.dart';
import '../../../sources/network_error_mapping.dart';
import '../../../sources/runtime/source_runtime.dart';
import '../../../sources/source.dart';
import '../../common/detail/media_detail_provider.dart';
import 'video_episode_panel.dart';
import 'video_fullscreen.dart';
import 'video_playback.dart';
import 'video_player_layout.dart';
import 'video_playlist.dart';
import 'video_progress.dart';
import 'video_touch_controls.dart';

/// 视频播放页（architecture §5.2「视频播放」、§6.4）：取 `content(unitId)` 的流，经本地媒体代理交给
/// media_kit（libmpv）播放。桌面用 media_kit 的桌面控件（快捷键、窗口全屏）；Android / iOS 用
/// [VideoTouchControls] 与页面内全屏（[VideoFullscreenController]）。清晰度与倍速在标题栏菜单
/// （移动端全屏时在顶栏）；选集与线路在画面下方（宽屏时在右侧）。
///
/// 播放器只拿到 `http://127.0.0.1:<port>/…` 的代理地址；上游请求全部由该源的网络层发出。
class VideoPlayerPage extends ConsumerStatefulWidget {
  const VideoPlayerPage({
    super.key,
    required this.sourceId,
    required this.itemId,
    required this.unitId,
    this.title,
    this.start,
  });

  final String sourceId;
  final String itemId;
  final String unitId;
  final String? title;

  /// 起始位置；为 null 时使用该剧集记录的进度。
  final Duration? start;

  @override
  ConsumerState<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

const _speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

class _VideoPlayerPageState extends ConsumerState<VideoPlayerPage> {
  late final Player _player = createVideoPlayer();
  late final VideoController _video = createVideoController(_player);
  late final PlayerVideoPlayback _playback = PlayerVideoPlayback(_player);
  final _fullscreen = VideoFullscreenController();
  late final _background = VideoBackgroundPause(
    enabled: () => mounted && _touch,
    onBackground: () {
      if (_player.state.playing) _player.pause().ignore();
    },
  );

  /// 播放器子树：全屏切换布局时保留状态。
  final _playerKey = GlobalKey();
  final _subscriptions = <StreamSubscription<Object?>>[];

  late String _unitId = widget.unitId;

  /// 当前所在线路（同一 id 出现在多条线路时用于定位）。
  int? _line;
  late Duration? _initialStart = widget.start;

  ProxiedStream? _stream;
  List<StreamRef> _streams = const [];
  int _streamIndex = -1;

  /// 用户选过的清晰度标签，换集时优先沿用。
  String? _quality;

  /// 写入历史的条目快照（详情加载后得到）。
  LibraryItem? _item;
  VideoPlaylist? _playlist;

  Object? _error;
  String? _playerError;

  /// 真正从起始位置开始播放之前为 true：用加载遮罩盖住画面并隐藏控件，不记录进度。
  bool _loading = true;
  bool _hardened = false;
  bool _autoNextHandled = false;
  double _rate = 1;
  int _generation = 0;

  /// 在 initState 中取得：dispose 时不能再使用 ref。
  late final VideoProgressRecorder _recorder;

  @override
  void initState() {
    super.initState();
    _recorder = ref.read(videoProgressRecorderProvider);
    _playback; // 尽早订阅播放器状态
    _fullscreen.addListener(_onFullscreenChanged);
    _background.attach();
    _subscriptions
      ..add(_player.stream.error.listen(_onPlayerError))
      ..add(_player.stream.position.listen((_) => _report()))
      ..add(
        _player.stream.playing.listen((playing) {
          if (!playing) _report(immediate: true);
        }),
      )
      ..add(_player.stream.completed.listen(_onCompleted))
      ..add(
        _player.stream.rate.listen((r) {
          if (mounted) setState(() => _rate = r);
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
      _subscriptions
        ..add(_player.stream.duration.listen((d) => log('duration $d')))
        ..add(_player.stream.buffering.listen((b) => log('buffering $b')))
        ..add(_player.stream.completed.listen((c) => log('completed $c')));
    }
    ref.listenManual(
      mediaDetailProvider(widget.sourceId, widget.itemId),
      (_, next) => _onDetail(next),
      fireImmediately: true,
    );
    _load();
  }

  // ---------------------------------------------------------------------------
  // 移动端：全屏、切到后台

  /// Android / iOS：触控控件、页面内全屏、切到后台时暂停。
  bool get _touch => isTouchVideoPlatform(Theme.of(context).platform);

  void _onFullscreenChanged() {
    if (mounted) setState(() {});
  }

  void _toggleFullscreen() {
    if (_fullscreen.isFullscreen) {
      _exitFullscreen();
      return;
    }
    final width = _player.state.width;
    final height = _player.state.height;
    _fullscreen
        .enter(
          aspectRatio:
              width != null && height != null && width > 0 && height > 0
              ? width / height
              : null,
        )
        .ignore();
  }

  void _exitFullscreen() {
    if (!mounted) return;
    final phone = MediaQuery.sizeOf(context).shortestSide < phoneShortestSide;
    _fullscreen.exit(phone: phone).ignore();
  }

  // ---------------------------------------------------------------------------
  // 详情、剧集与进度

  void _onDetail(AsyncValue<MediaDetailData> value) {
    final data = value.value;
    if (data == null) return;
    final playlist = VideoPlaylist(data.detail);
    setState(() {
      _playlist = playlist;
      _line = playlist.locate(_unitId, preferLine: _line)?.line ?? _line;
    });
    videoItemSnapshot(
      library: ref.read(libraryRepositoryProvider),
      history: ref.read(historyRepositoryProvider),
      sourceId: widget.sourceId,
      itemId: widget.itemId,
      detail: data.detail,
      sourceHeaders: data.sourceHeaders,
    ).then((item) {
      if (!mounted) return;
      _item = item;
      _report();
    }, onError: (Object e) => debugPrint('[player] item snapshot: $e'));
  }

  EpisodeLocation? get _location =>
      _playlist?.locate(_unitId, preferLine: _line);

  String? get _unitTitle {
    final at = _location;
    return (at == null ? null : _playlist?.unitAt(at)?.title) ?? widget.title;
  }

  /// 报告当前进度（加载中、详情未到时不报告）。
  void _report({bool immediate = false}) {
    final item = _item;
    final title = _unitTitle;
    if (_loading || _error != null || item == null || title == null) return;
    final state = _player.state;
    _recorder.report(
      VideoPlaybackProgress(
        item: item,
        unitId: _unitId,
        unitTitle: title,
        position: state.position,
        finished: isFinished(
          state.position,
          state.duration,
          completed: state.completed,
        ),
      ),
      immediate: immediate,
    );
  }

  void _onCompleted(bool completed) {
    if (!completed || _loading || _autoNextHandled || !mounted) return;
    _report(immediate: true);
    final at = _location;
    final next = at == null ? null : _playlist?.neighbor(at, 1);
    if (next == null) return; // 最后一集：停在结尾
    _autoNextHandled = true;
    _openEpisode(next);
  }

  void _onPlayerError(String e) {
    if (!mounted) return;
    // 代理记录的上游失败（白名单、人机验证、超时……）比播放器的错误文字更有用：
    // 人机验证 / 登录时显示「打开验证页」，完成后重新加载。
    final failure = _stream?.lastFailure;
    _exitFullscreen();
    setState(() {
      if (failure != null) {
        _error = failure.toSourceException();
      } else {
        _playerError = e;
      }
    });
  }

  /// 换到 [at]；[start] 为 null 时使用该剧集记录的进度。
  void _openEpisode(EpisodeLocation at, {Duration? start}) {
    final unit = _playlist?.unitAt(at);
    if (unit == null) return;
    _report(immediate: true);
    setState(() {
      _unitId = unit.id;
      _line = at.line;
    });
    _load(start: start);
  }

  void _switchLine(int line) {
    final at = _location;
    if (at == null) return;
    final target = _playlist?.switchLine(at, line);
    if (target == null) return;
    // 同一集的另一条线路：保持当前位置。
    _openEpisode(target, start: _loading ? null : _player.state.position);
  }

  void _switchStream(int index) {
    if (index == _streamIndex || index < 0 || index >= _streams.length) return;
    final start = _loading ? _initialStart : _player.state.position;
    _report(immediate: true);
    _quality = streamLabel(_streams, index);
    _play(index, start: start ?? Duration.zero);
  }

  /// 起始位置：显式给出的 → 该剧集记录的进度 → 0。
  Future<Duration> _resolveStart(Duration? start) async {
    if (start != null) return start;
    final initial = _initialStart;
    if (initial != null && _unitId == widget.unitId) {
      _initialStart = null;
      return initial;
    }
    final saved = await ref
        .read(historyRepositoryProvider)
        .unitProgress(widget.sourceId, widget.itemId, _unitId);
    final ms = saved?.position;
    return ms != null && ms > 0 ? Duration(milliseconds: ms) : Duration.zero;
  }

  // ---------------------------------------------------------------------------
  // 加载与播放

  /// 这次加载仍是最新的（没有被重试、换集或页面销毁取代）。
  bool _current(int generation) => mounted && generation == _generation;

  /// 取当前剧集的 content 并播放。
  Future<void> _load({Duration? start}) async {
    // 上一集的流在新一集的 content 到达前不可再选（否则会以旧流播放、进度记到新一集）。
    _streams = const [];
    _streamIndex = -1;
    final generation = _begin();
    try {
      final source = await ref.read(
        sourceInstanceProvider(widget.sourceId).future,
      );
      final unitId = _unitId;
      final content = await source.content(unitId);
      if (!_current(generation)) return;
      if (content is! VideoContent) {
        throw const SourceException(SourceErrorCode.parse, '内容不是视频');
      }
      final streams = playableStreams(content);
      if (streams.isEmpty) {
        throw SourceException(
          SourceErrorCode.unsupported,
          content.streams.isEmpty ? '没有可播放的流' : '暂不支持 DASH',
        );
      }
      final from = await _resolveStart(start);
      if (!_current(generation)) return;
      _streams = streams;
      await _open(generation, pickStream(streams, _quality), from);
    } on Object catch (e) {
      _fail(generation, e);
    }
  }

  /// 换清晰度：沿用已取得的流列表。
  Future<void> _play(int index, {required Duration start}) async {
    final generation = _begin();
    try {
      await _open(generation, index, start);
    } on Object catch (e) {
      _fail(generation, e);
    }
  }

  int _begin() {
    final generation = ++_generation;
    _stream?.close();
    _stream = null;
    _autoNextHandled = false;
    setState(() {
      _loading = true;
      _error = null;
      _playerError = null;
    });
    return generation;
  }

  Future<void> _open(int generation, int index, Duration start) async {
    setState(() => _streamIndex = index);
    final proxied = await ref.read(openProxiedStreamProvider)(
      widget.sourceId,
      _streams[index],
    );
    if (!_current(generation)) {
      proxied.close();
      return;
    }
    _stream = proxied;
    if (!_hardened) {
      await hardenVideoPlayer(_player);
      _hardened = true;
      if (!_current(generation)) return;
    }
    final opened = DateTime.now();
    await openVideo(
      _player,
      _video,
      proxied.url.toString(),
      start: start,
      stillCurrent: () => _current(generation),
    );
    if (!_current(generation)) return;
    // 加载期间切到了后台（含后台播完自动打开下一集）：不在后台继续播放。
    if (_background.inBackground) await _player.pause();
    if (!_current(generation)) return;
    debugPrint(
      '[player] started: ${DateTime.now().difference(opened).inMilliseconds} ms '
      'start=$start position=${_player.state.position} '
      'duration=${_player.state.duration} completed=${_player.state.completed}',
    );
    setState(() => _loading = false);
    _report(immediate: true);
    // 诊断：实际使用的解码路径（真机比较 hwdec 时看 logcat）。
    if (videoVerboseLogs) {
      Future<void>.delayed(const Duration(seconds: 1), () async {
        if (!_current(generation)) return;
        debugPrint('[player] decoder ${await describeVideoDecoder(_player)}');
      });
    }
  }

  void _fail(int generation, Object e) {
    if (!_current(generation)) return;
    _exitFullscreen();
    setState(() {
      _error = e;
      _loading = false;
    });
  }

  @override
  void dispose() {
    _report(immediate: true);
    _generation++; // 进行中的加载不再操作播放器
    _background.detach();
    _fullscreen
      ..removeListener(_onFullscreenChanged)
      ..restore().ignore()
      ..dispose();
    _playback.dispose();
    for (final s in _subscriptions) {
      s.cancel().ignore();
    }
    _player.dispose().ignore();
    _stream?.close();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // 界面

  @override
  Widget build(BuildContext context) {
    final playlist = _playlist;
    final readUnits =
        ref.watch(readUnitIdsProvider(widget.sourceId, widget.itemId)).value ??
        const <String>{};
    final panel = playlist == null
        ? const Center(child: CircularProgressIndicator())
        : VideoEpisodePanel(
            playlist: playlist,
            current: _location,
            readUnitIds: readUnits,
            onOpen: _openEpisode,
            onSwitchLine: _switchLine,
          );

    return VideoPlayerLayout(
      fullscreen: _fullscreen.isFullscreen,
      onExitFullscreen: _exitFullscreen,
      appBar: AppBar(title: Text(_unitTitle ?? '播放'), actions: _menus()),
      player: KeyedSubtree(key: _playerKey, child: _buildPlayer(context)),
      panel: panel,
    );
  }

  /// 清晰度与倍速菜单（标题栏；移动端全屏时在顶栏）。
  List<Widget> _menus() => [
    if (_streams.length > 1)
      PopupMenuButton<int>(
        tooltip: '清晰度',
        initialValue: _streamIndex,
        onSelected: _switchStream,
        itemBuilder: (_) => [
          for (var i = 0; i < _streams.length; i++)
            PopupMenuItem(value: i, child: Text(streamLabel(_streams, i))),
        ],
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Center(
            child: Text(
              _streamIndex >= 0 ? streamLabel(_streams, _streamIndex) : '',
            ),
          ),
        ),
      ),
    PopupMenuButton<double>(
      tooltip: '倍速',
      initialValue: _rate,
      onSelected: _player.setRate,
      itemBuilder: (_) => [
        for (final s in _speeds) PopupMenuItem(value: s, child: Text('${s}x')),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Center(child: Text('${_rate}x')),
      ),
    ),
  ];

  Widget _buildPlayer(BuildContext context) {
    if (_error case final error?) {
      return ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Center(
          child: SingleChildScrollView(
            child: SourceErrorView(
              error: error,
              sourceId: widget.sourceId,
              onRetry: _load,
            ),
          ),
        ),
      );
    }
    final touch = _touch;
    return Column(
      children: [
        Expanded(
          child: Stack(
            alignment: Alignment.center,
            children: [
              // 真正从起始位置开始播放之前不显示控件，用加载遮罩盖住画面与进度。
              // 常亮：Video 的 wakelock 随播放状态开关（architecture §5.2「屏幕常亮」）。
              Video(
                controller: _video,
                controls: touch || _loading
                    ? NoVideoControls
                    : AdaptiveVideoControls,
                // 移动端由 _background 处理（含加载期间切到后台）；桌面沿用 media_kit 的默认行为。
                pauseUponEnteringBackgroundMode: !touch,
              ),
              if (_loading)
                const Positioned.fill(
                  child: ColoredBox(
                    color: Colors.black,
                    child: Center(child: CircularProgressIndicator()),
                  ),
                ),
              if (touch)
                Positioned.fill(
                  child: VideoTouchControls(
                    playback: _playback,
                    loading: _loading,
                    fullscreen: _fullscreen.isFullscreen,
                    onToggleFullscreen: _toggleFullscreen,
                    onBack: _exitFullscreen,
                    title: _unitTitle,
                    actions: _menus(),
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
              trailing: TextButton(onPressed: _load, child: const Text('重试')),
            ),
          ),
      ],
    );
  }
}
