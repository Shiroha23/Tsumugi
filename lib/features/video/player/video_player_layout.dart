import 'package:flutter/material.dart';

/// 播放页的布局（architecture §5.2「移动端全屏」）。
///
/// 非全屏：标题栏 + 播放器 + 选集面板（宽 ≥ 900 时面板在右侧，否则在下方、播放器 16:9）。
/// 全屏：只有黑底上的播放器；返回键 / 返回手势先调用 [onExitFullscreen]，不离开页面。
/// [player] 应带 `GlobalKey`，切换时保留状态。
class VideoPlayerLayout extends StatelessWidget {
  const VideoPlayerLayout({
    super.key,
    required this.fullscreen,
    required this.appBar,
    required this.player,
    required this.panel,
    required this.onExitFullscreen,
  });

  final bool fullscreen;
  final PreferredSizeWidget appBar;
  final Widget player;
  final Widget panel;
  final VoidCallback onExitFullscreen;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !fullscreen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && fullscreen) onExitFullscreen();
      },
      child: fullscreen
          ? Scaffold(backgroundColor: Colors.black, body: player)
          : Scaffold(
              appBar: appBar,
              body: LayoutBuilder(
                builder: (context, constraints) {
                  if (constraints.maxWidth >= 900) {
                    return Row(
                      children: [
                        Expanded(child: player),
                        SizedBox(width: 320, child: panel),
                      ],
                    );
                  }
                  return Column(
                    children: [
                      AspectRatio(aspectRatio: 16 / 9, child: player),
                      Expanded(child: panel),
                    ],
                  );
                },
              ),
            ),
    );
  }
}
