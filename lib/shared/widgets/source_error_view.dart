import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../sources/runtime/source_error_text.dart';
import '../webview/providers.dart';

/// 显示源调用失败的原因（§6 错误码的中文提示），可选「重试」。
///
/// `E_CHALLENGE` / `E_LOGIN_REQUIRED` 且给出 [sourceId] 时额外显示「打开验证页」：在 WebView 中让用户
/// **手动**完成验证或登录（architecture §5.3），完成后 Cookie 写回该源并自动调用 [onRetry]。
/// 客户端不做任何自动绕过。
class SourceErrorView extends ConsumerStatefulWidget {
  const SourceErrorView({
    super.key,
    required this.error,
    this.sourceId,
    this.onRetry,
    this.compact = false,
  });

  final Object error;

  /// 出错的源；为 null 时不提供「打开验证页」。
  final String? sourceId;
  final VoidCallback? onRetry;

  /// 紧凑模式：用于搜索结果分组内的一行。
  final bool compact;

  @override
  ConsumerState<SourceErrorView> createState() => _SourceErrorViewState();
}

class _SourceErrorViewState extends ConsumerState<SourceErrorView> {
  bool _verifying = false;

  Future<void> _openVerification() async {
    final sourceId = widget.sourceId;
    if (sourceId == null || _verifying) return;
    setState(() => _verifying = true);
    try {
      final done = await ref
          .read(sourceVerificationProvider)
          .verifySource(sourceId);
      // 等待期间视图可能已销毁或被复用到另一个源上。
      if (done && mounted && widget.sourceId == sourceId) {
        widget.onRetry?.call();
      }
    } on Object catch (e) {
      if (mounted) {
        final info = describeSourceError(e);
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text('无法打开验证页：${info.detail ?? info.title}')),
        );
      }
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = describeSourceError(widget.error);
    final onRetry = widget.onRetry;
    final scheme = Theme.of(context).colorScheme;
    final actions = [
      if (info.needsVerification && widget.sourceId != null)
        TextButton.icon(
          icon: const Icon(Icons.verified_user_outlined),
          label: const Text('打开验证页'),
          onPressed: _verifying ? null : _openVerification,
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

    if (widget.compact) {
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
}
