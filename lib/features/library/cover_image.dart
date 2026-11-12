import 'package:flutter/material.dart';

import '../../sources/model/common.dart';

/// 条目封面，固定 3:4 比例；无封面或加载失败时显示占位图标。
class CoverImage extends StatelessWidget {
  const CoverImage({super.key, required this.url, this.headers});

  final String? url;
  final Headers? headers;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final placeholder = ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: Center(
        child: Icon(Icons.image_outlined, color: scheme.onSurfaceVariant),
      ),
    );
    final url = this.url;
    return AspectRatio(
      aspectRatio: 3 / 4,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: url == null || url.isEmpty
            ? placeholder
            // TODO(m2): 换成阅读器会话提供的统一图片加载器（缓存 + 源 HTTP 客户端 + 主机白名单）。
            : Image.network(
                url,
                headers: headers,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => placeholder,
              ),
      ),
    );
  }
}
