import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

/// 触控控件所需的播放状态（architecture §5.2「视频播放」）。
@immutable
class VideoPlaybackState {
  const VideoPlaybackState({
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.playing = false,
    this.buffering = false,
    this.rate = 1,
  });

  final Duration position;
  final Duration duration;
  final bool playing;
  final bool buffering;
  final double rate;

  VideoPlaybackState copyWith({
    Duration? position,
    Duration? duration,
    bool? playing,
    bool? buffering,
    double? rate,
  }) => VideoPlaybackState(
    position: position ?? this.position,
    duration: duration ?? this.duration,
    playing: playing ?? this.playing,
    buffering: buffering ?? this.buffering,
    rate: rate ?? this.rate,
  );

  @override
  bool operator ==(Object other) =>
      other is VideoPlaybackState &&
      other.position == position &&
      other.duration == duration &&
      other.playing == playing &&
      other.buffering == buffering &&
      other.rate == rate;

  @override
  int get hashCode => Object.hash(position, duration, playing, buffering, rate);
}

/// 控件操作播放器的接口：页面用 [PlayerVideoPlayback]，widget 测试用假实现。
abstract interface class VideoPlayback
    implements ValueListenable<VideoPlaybackState> {
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> setRate(double rate);
}

/// 把 media_kit 的 [Player] 适配为 [VideoPlayback]。
class PlayerVideoPlayback extends ValueNotifier<VideoPlaybackState>
    implements VideoPlayback {
  PlayerVideoPlayback(this._player)
    : super(
        VideoPlaybackState(
          position: _player.state.position,
          duration: _player.state.duration,
          playing: _player.state.playing,
          buffering: _player.state.buffering,
          rate: _player.state.rate,
        ),
      ) {
    final s = _player.stream;
    _subscriptions.addAll([
      s.position.listen((v) => value = value.copyWith(position: v)),
      s.duration.listen((v) => value = value.copyWith(duration: v)),
      s.playing.listen((v) => value = value.copyWith(playing: v)),
      s.buffering.listen((v) => value = value.copyWith(buffering: v)),
      s.rate.listen((v) => value = value.copyWith(rate: v)),
    ]);
  }

  final Player _player;
  final _subscriptions = <StreamSubscription<Object?>>[];

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setRate(double rate) => _player.setRate(rate);

  @override
  void dispose() {
    for (final s in _subscriptions) {
      s.cancel().ignore();
    }
    super.dispose();
  }
}
