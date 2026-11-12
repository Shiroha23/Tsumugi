import 'package:flutter/material.dart';

import '../../../shared/image/source_image.dart';

/// 阅读器中的单页图片：自行监听 [ImageStream]，以便把图片宽高比报告给阅读器
/// （纵向模式据此计算每页高度）。加载中显示进度，失败显示重试。
class ReaderPageImage extends StatefulWidget {
  const ReaderPageImage({
    super.key,
    required this.image,
    required this.pageNumber,
    this.fit = BoxFit.contain,
    this.onAspectRatio,
  });

  final ImageProvider image;

  /// 从 1 开始，仅用于占位显示。
  final int pageNumber;
  final BoxFit fit;

  /// 解码出图片后调用（宽 / 高）。
  final ValueChanged<double>? onAspectRatio;

  @override
  State<ReaderPageImage> createState() => _ReaderPageImageState();
}

class _ReaderPageImageState extends State<ReaderPageImage> {
  ImageStream? _stream;
  ImageInfo? _info;
  ImageChunkEvent? _chunk;
  Object? _error;
  late final _listener = ImageStreamListener(
    _onImage,
    onChunk: (e) {
      if (mounted) setState(() => _chunk = e);
    },
    onError: (e, _) {
      if (mounted) setState(() => _error = e);
    },
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(ReaderPageImage old) {
    super.didUpdateWidget(old);
    if (old.image != widget.image) _resolve();
  }

  void _resolve() {
    final stream = widget.image.resolve(createLocalImageConfiguration(context));
    if (stream.key == _stream?.key) return;
    _stream?.removeListener(_listener);
    _stream = stream..addListener(_listener);
  }

  void _onImage(ImageInfo info, bool _) {
    if (!mounted) {
      info.dispose();
      return;
    }
    final old = _info;
    setState(() {
      _info = info;
      _error = null;
      _chunk = null;
    });
    old?.dispose();
    if (info.image.height > 0) {
      widget.onAspectRatio?.call(info.image.width / info.image.height);
    }
  }

  void _retry() {
    _stream?.removeListener(_listener);
    _stream = null;
    widget.image.evict();
    setState(() {
      _error = null;
      _chunk = null;
    });
    _resolve();
  }

  @override
  void dispose() {
    _stream?.removeListener(_listener);
    _info?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_info case final info?) {
      return RawImage(
        image: info.image,
        scale: info.scale,
        fit: widget.fit,
        width: double.infinity,
        height: double.infinity,
        filterQuality: FilterQuality.medium,
      );
    }
    final color = Colors.white54;
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${widget.pageNumber}', style: TextStyle(color: color)),
            const SizedBox(height: 8),
            Theme(
              data: ThemeData.dark(),
              child: ImageErrorPlaceholder(onRetry: _retry),
            ),
          ],
        ),
      );
    }
    final total = _chunk?.expectedTotalBytes;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('${widget.pageNumber}', style: TextStyle(color: color)),
          const SizedBox(height: 8),
          SizedBox.square(
            dimension: 28,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              color: color,
              value: total != null && total > 0
                  ? _chunk!.cumulativeBytesLoaded / total
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}
