import 'dart:async';

import 'package:flutter/material.dart';

import 'video_playback.dart';

/// `m:ss`，一小时以上为 `h:mm:ss`。
String formatVideoTime(Duration d) {
  if (d.isNegative) d = Duration.zero;
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
}

/// Android / iOS 的触控控件（architecture §5.2「控件」），叠在不带控件的 `Video` 上。
///
/// 单击显示 / 隐藏；双击播放 / 暂停；横向拖动定位（松手才 seek）；长按临时 [boostRate] 倍速。
class VideoTouchControls extends StatefulWidget {
  const VideoTouchControls({
    super.key,
    required this.playback,
    required this.onToggleFullscreen,
    this.fullscreen = false,
    this.loading = false,
    this.onBack,
    this.title,
    this.actions = const [],
    this.hideAfter = const Duration(seconds: 3),
    this.boostRate = 2,
    this.dragSpan = const Duration(seconds: 90),
  });

  final VideoPlayback playback;
  final VoidCallback onToggleFullscreen;
  final bool fullscreen;

  /// 加载中：不响应手势、不显示底栏；全屏时仍显示顶栏（返回）。
  final bool loading;

  /// 全屏顶栏的返回按钮。
  final VoidCallback? onBack;
  final String? title;

  /// 全屏顶栏右侧的菜单（清晰度 / 倍速）。
  final List<Widget> actions;

  /// 播放中无操作多久后自动隐藏。
  final Duration hideAfter;
  final double boostRate;

  /// 横向拖过整个宽度对应的时长（不超过视频时长）。
  final Duration dragSpan;

  @override
  State<VideoTouchControls> createState() => _VideoTouchControlsState();
}

class _VideoTouchControlsState extends State<VideoTouchControls> {
  bool _visible = true;
  Timer? _hideTimer;

  /// 横向拖动：起点与目标位置。
  Duration? _dragFrom;
  Duration? _dragTarget;
  double _dragDx = 0;

  /// 进度条拖动中的位置（秒）。
  double? _scrub;

  /// 长按倍速前的倍速；为 null 时不在长按中。
  double? _boostFrom;

  VideoPlayback get _playback => widget.playback;

  @override
  void initState() {
    super.initState();
    _wasPlaying = _playback.value.playing;
    _playback.addListener(_onPlayback);
    _scheduleHide();
  }

  @override
  void didUpdateWidget(VideoTouchControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playback != widget.playback) {
      oldWidget.playback.removeListener(_onPlayback);
      widget.playback.addListener(_onPlayback);
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _playback.removeListener(_onPlayback);
    super.dispose();
  }

  bool _wasPlaying = false;

  void _onPlayback() {
    final playing = _playback.value.playing;
    if (playing != _wasPlaying) {
      _wasPlaying = playing;
      // 暂停时控件保持当前状态；开始播放时重新计时。
      if (playing) {
        _scheduleHide();
      } else {
        _hideTimer?.cancel();
      }
    }
    if (mounted) setState(() {});
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (!_visible || !_playback.value.playing) return;
    _hideTimer = Timer(widget.hideAfter, () {
      if (mounted && _scrub == null) setState(() => _visible = false);
    });
  }

  /// 控件上的操作：保持显示并重新计时。
  void _touch() {
    if (!_visible) setState(() => _visible = true);
    _scheduleHide();
  }

  void _onTap() {
    setState(() => _visible = !_visible);
    _scheduleHide();
  }

  void _playOrPause() {
    if (_playback.value.playing) {
      _playback.pause();
    } else {
      _playback.play();
    }
  }

  void _onDragStart(DragStartDetails _) {
    final state = _playback.value;
    if (state.duration <= Duration.zero) return; // 直播等无时长的流
    setState(() {
      _dragFrom = state.position;
      _dragTarget = state.position;
      _dragDx = 0;
    });
  }

  void _onDragUpdate(DragUpdateDetails details, double width) {
    final from = _dragFrom;
    if (from == null || width <= 0) return;
    final duration = _playback.value.duration;
    _dragDx += details.delta.dx;
    final span = widget.dragSpan < duration ? widget.dragSpan : duration;
    final offset = span * (_dragDx / width);
    var target = from + offset;
    if (target < Duration.zero) target = Duration.zero;
    if (target > duration) target = duration;
    setState(() => _dragTarget = target);
  }

  void _onDragEnd([Object? _]) {
    final target = _dragTarget;
    final from = _dragFrom;
    setState(() {
      _dragFrom = null;
      _dragTarget = null;
      _dragDx = 0;
    });
    if (target != null && from != null && target != from) {
      _playback.seek(target);
    }
  }

  void _onLongPressStart(LongPressStartDetails _) {
    final state = _playback.value;
    if (!state.playing || state.rate >= widget.boostRate) return;
    setState(() => _boostFrom = state.rate);
    _playback.setRate(widget.boostRate);
  }

  void _onLongPressEnd([Object? _]) {
    final from = _boostFrom;
    if (from == null) return;
    setState(() => _boostFrom = null);
    _playback.setRate(from);
  }

  @override
  Widget build(BuildContext context) {
    final state = _playback.value;
    final loading = widget.loading;
    final showBars = _visible || loading;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              key: const ValueKey('video-gesture-area'),
              behavior: HitTestBehavior.opaque,
              onTap: loading ? null : _onTap,
              onDoubleTap: loading ? null : _playOrPause,
              onHorizontalDragStart: loading ? null : _onDragStart,
              onHorizontalDragUpdate: loading
                  ? null
                  : (d) => _onDragUpdate(d, width),
              onHorizontalDragEnd: loading ? null : _onDragEnd,
              onHorizontalDragCancel: loading ? null : _onDragEnd,
              onLongPressStart: loading ? null : _onLongPressStart,
              onLongPressEnd: loading ? null : _onLongPressEnd,
              onLongPressCancel: loading ? null : _onLongPressEnd,
            ),
            if (!loading && state.buffering)
              const Center(
                child: IgnorePointer(
                  child: CircularProgressIndicator(color: Colors.white),
                ),
              ),
            if (_dragTarget case final target?)
              Center(
                child: IgnorePointer(
                  child: _Badge(
                    key: const ValueKey('video-seek-indicator'),
                    text:
                        '${formatVideoTime(target)} / ${formatVideoTime(state.duration)}',
                    large: true,
                  ),
                ),
              ),
            if (_boostFrom != null)
              Align(
                alignment: const Alignment(0, -0.7),
                child: IgnorePointer(
                  child: _Badge(
                    key: const ValueKey('video-boost-indicator'),
                    text: '${_rateLabel(widget.boostRate)} 倍速中',
                  ),
                ),
              ),
            if (widget.fullscreen)
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                child: _Bar(
                  visible: showBars,
                  top: true,
                  child: _buildTopBar(context),
                ),
              ),
            if (!loading)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _Bar(
                  visible: _visible,
                  top: false,
                  child: _buildBottomBar(context, state),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildTopBar(BuildContext context) => Row(
    children: [
      IconButton(
        tooltip: '退出全屏',
        icon: const Icon(Icons.arrow_back),
        onPressed: widget.onBack,
      ),
      Expanded(
        child: Text(
          widget.title ?? '',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 16),
        ),
      ),
      ...widget.actions,
    ],
  );

  Widget _buildBottomBar(BuildContext context, VideoPlaybackState state) {
    final max = state.duration.inMilliseconds / 1000;
    final position = (_scrub ?? state.position.inMilliseconds / 1000).clamp(
      0.0,
      max > 0 ? max : 0.0,
    );
    return Row(
      children: [
        IconButton(
          tooltip: state.playing ? '暂停' : '播放',
          icon: Icon(state.playing ? Icons.pause : Icons.play_arrow),
          onPressed: () {
            _touch();
            _playOrPause();
          },
        ),
        Text(
          formatVideoTime(
            _scrub != null
                ? Duration(milliseconds: (_scrub! * 1000).round())
                : state.position,
          ),
        ),
        Expanded(
          child: Slider(
            value: position,
            max: max > 0 ? max : 1,
            onChanged: max > 0
                ? (v) {
                    _hideTimer?.cancel();
                    setState(() => _scrub = v);
                  }
                : null,
            onChangeEnd: max > 0
                ? (v) {
                    setState(() => _scrub = null);
                    _playback.seek(Duration(milliseconds: (v * 1000).round()));
                    _scheduleHide();
                  }
                : null,
          ),
        ),
        Text(formatVideoTime(state.duration)),
        IconButton(
          tooltip: widget.fullscreen ? '退出全屏' : '全屏',
          icon: Icon(
            widget.fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
          ),
          onPressed: () {
            _touch();
            widget.onToggleFullscreen();
          },
        ),
      ],
    );
  }
}

String _rateLabel(double rate) =>
    rate == rate.roundToDouble() ? '${rate.toInt()}x' : '${rate}x';

/// 顶栏 / 底栏：半透明渐变背景，隐藏时不接收触摸。
class _Bar extends StatelessWidget {
  const _Bar({required this.visible, required this.top, required this.child});

  final bool visible;
  final bool top;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 150),
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: top ? Alignment.topCenter : Alignment.bottomCenter,
              end: top ? Alignment.bottomCenter : Alignment.topCenter,
              colors: const [Color(0xAA000000), Color(0x00000000)],
            ),
          ),
          child: SafeArea(
            top: top,
            bottom: !top,
            child: IconTheme.merge(
              data: const IconThemeData(color: Colors.white),
              child: DefaultTextStyle.merge(
                style: const TextStyle(color: Colors.white),
                child: SliderTheme(
                  data: theme.sliderTheme.copyWith(
                    activeTrackColor: Colors.white,
                    inactiveTrackColor: Colors.white38,
                    thumbColor: Colors.white,
                  ),
                  child: Material(
                    type: MaterialType.transparency,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: child,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({super.key, required this.text, this.large = false});

  final String text;
  final bool large;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: const Color(0xAA000000),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Padding(
      padding: EdgeInsets.symmetric(
        horizontal: large ? 16 : 12,
        vertical: large ? 10 : 6,
      ),
      child: Text(
        text,
        style: TextStyle(color: Colors.white, fontSize: large ? 20 : 14),
      ),
    ),
  );
}
