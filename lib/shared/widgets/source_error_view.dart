import 'package:flutter/material.dart';

import '../../sources/runtime/source_error_text.dart';

/// 显示源调用失败的原因（§6 错误码的中文提示），可选「重试」。
///
/// `E_CHALLENGE` 额外显示「去验证」入口：将来在 WebView 中让用户**手动**完成验证
/// （architecture §5.3），客户端不做任何自动绕过。
class SourceErrorView extends StatelessWidget {
  const SourceErrorView({
    super.key,
    required this.error,
    this.onRetry,
    this.compact = false,
  });

  final Object error;
  final VoidCallback? onRetry;

  /// 紧凑模式：用于搜索结果分组内的一行。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final info = describeSourceError(error);
    final scheme = Theme.of(context).colorScheme;
    final actions = [
      if (info.needsVerification)
        TextButton.icon(
          icon: const Icon(Icons.verified_user_outlined),
          label: const Text('去验证'),
          onPressed: () => _openVerification(context),
        ),
      if (onRetry != null)
        TextButton.icon(
          icon: const Icon(Icons.refresh),
          label: const Text('重试'),
          onPressed: onRetry,
        ),
    ];
    final icon = Icon(
      info.needsVerification ? Icons.gpp_maybe_outlined : Icons.error_outline,
      color: scheme.error,
    );
    final detail = info.detail;

    if (compact) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
        child: Row(
          children: [
            icon,
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(info.title),
                  if (detail != null)
                    Text(
                      detail,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                ],
              ),
            ),
            ...actions,
          ],
        ),
      );
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon.icon, size: 48, color: scheme.error),
            const SizedBox(height: 12),
            Text(info.title, style: Theme.of(context).textTheme.titleMedium),
            if (detail != null) ...[
              const SizedBox(height: 8),
              Text(
                detail,
                textAlign: TextAlign.center,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ],
            if (actions.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(spacing: 8, children: actions),
            ],
          ],
        ),
      ),
    );
  }

  // TODO(m3): 打开 WebView 让用户手动完成验证，完成后把 Cookie 回写到该源的 Cookie 域并重试。
  void _openVerification(BuildContext context) {
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('WebView 验证尚未实现')));
  }
}
