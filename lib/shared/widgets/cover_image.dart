import 'package:flutter/material.dart';

/// 封面图。[headers] 来自源（如 `coverHeaders`），随图片请求发送。
///
/// TODO(m2): 换成统一的图片加载器（带磁盘缓存、按源 headers / Cookie）。
class CoverImage extends StatelessWidget {
  const CoverImage({
    super.key,
    required this.url,
    this.headers,
    this.width,
    this.height,
  });

  final String? url;
  final Map<String, String>? headers;
  final double? width;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final placeholder = Container(
      width: width,
      height: height,
      color: scheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Icon(Icons.image_outlined, color: scheme.onSurfaceVariant),
    );
    final src = url;
    if (src == null || src.isEmpty) return placeholder;
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.network(
        src,
        headers: headers,
        width: width,
        height: height,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => placeholder,
        frameBuilder: (_, child, frame, sync) =>
            sync || frame != null ? child : placeholder,
      ),
    );
  }
}
