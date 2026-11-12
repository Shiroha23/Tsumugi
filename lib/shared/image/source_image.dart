import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../sources/model/common.dart';
import '../../sources/model/content.dart';
import 'image_providers.dart';
import 'source_image_provider.dart';

/// 便捷方法：为 [ref] 构造使用全局加载器的 [SourceImageProvider]。
extension SourceImageRefX on WidgetRef {
  SourceImageProvider sourceImage(String sourceId, ImageRef image) =>
      SourceImageProvider(
        sourceId: sourceId,
        ref: image,
        loader: read(sourceImageLoaderProvider),
      );
}

/// 显示一张源图片：加载中显示进度，失败显示可点击重试的占位。替代 `Image.network`。
class SourceImage extends ConsumerStatefulWidget {
  const SourceImage({
    super.key,
    required this.sourceId,
    required this.image,
    this.width,
    this.height,
    this.fit,
    this.alignment = Alignment.center,
    this.placeholder,
    this.errorWidget,
    this.semanticLabel,
  });

  final String sourceId;
  final ImageRef image;
  final double? width;
  final double? height;
  final BoxFit? fit;
  final AlignmentGeometry alignment;

  /// 加载中显示；默认为居中的进度指示器。
  final Widget? placeholder;

  /// 失败时显示；为 null 时显示默认的“点击重试”占位。
  final Widget Function(BuildContext context, Object error, VoidCallback retry)?
  errorWidget;
  final String? semanticLabel;

  @override
  ConsumerState<SourceImage> createState() => _SourceImageState();
}

class _SourceImageState extends ConsumerState<SourceImage> {
  int _attempt = 0;

  void _retry(SourceImageProvider provider) {
    provider.evict();
    setState(() => _attempt++);
  }

  @override
  Widget build(BuildContext context) {
    final provider = ref.sourceImage(widget.sourceId, widget.image);
    return Image(
      key: ValueKey(_attempt),
      image: provider,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      alignment: widget.alignment,
      semanticLabel: widget.semanticLabel,
      gaplessPlayback: true,
      loadingBuilder: (context, child, progress) {
        if (progress == null) return child;
        return _sized(
          widget.placeholder ??
              Center(
                child: CircularProgressIndicator(
                  value: switch (progress.expectedTotalBytes) {
                    final t? when t > 0 => progress.cumulativeBytesLoaded / t,
                    _ => null,
                  },
                ),
              ),
        );
      },
      errorBuilder: (context, error, _) {
        void retry() => _retry(provider);
        return _sized(
          widget.errorWidget?.call(context, error, retry) ??
              ImageErrorPlaceholder(onRetry: retry),
        );
      },
    );
  }

  Widget _sized(Widget child) =>
      SizedBox(width: widget.width, height: widget.height, child: child);
}

/// 默认的图片失败占位：图标 + “点击重试”。
class ImageErrorPlaceholder extends StatelessWidget {
  const ImageErrorPlaceholder({super.key, this.onRetry, this.compact = false});

  final VoidCallback? onRetry;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onRetry,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.broken_image_outlined, color: scheme.outline),
            if (!compact && onRetry != null)
              Text(
                '点击重试',
                style: TextStyle(color: scheme.outline, fontSize: 12),
              ),
          ],
        ),
      ),
    );
  }
}

/// 封面：固定比例（默认 3:4）、圆角、无地址时显示占位。用于书架 / 搜索 / 详情。
class CoverImage extends StatelessWidget {
  const CoverImage({
    super.key,
    required this.sourceId,
    required this.url,
    this.headers,
    this.width,
    this.aspectRatio = 3 / 4,
    this.borderRadius = const BorderRadius.all(Radius.circular(6)),
  });

  final String sourceId;

  /// 封面地址（`SearchItem.cover` / `Detail.cover`）；null 或空串显示占位。
  final String? url;

  /// `SearchItem.coverHeaders`。
  final Headers? headers;
  final double? width;
  final double aspectRatio;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final url = this.url;
    return SizedBox(
      width: width,
      child: AspectRatio(
        aspectRatio: aspectRatio,
        child: ClipRRect(
          borderRadius: borderRadius,
          child: ColoredBox(
            color: scheme.surfaceContainerHighest,
            child: url == null || url.isEmpty
                ? Icon(Icons.image_outlined, color: scheme.outline)
                : SourceImage(
                    sourceId: sourceId,
                    image: ImageRef(url: url, headers: headers),
                    fit: BoxFit.cover,
                    width: double.infinity,
                    height: double.infinity,
                    placeholder: const SizedBox.shrink(),
                    errorWidget: (_, _, retry) =>
                        ImageErrorPlaceholder(onRetry: retry, compact: true),
                  ),
          ),
        ),
      ),
    );
  }
}
