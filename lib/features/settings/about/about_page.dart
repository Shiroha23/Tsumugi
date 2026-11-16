import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// 源码仓库地址（GPL-3.0 §6：对应源码；原生组件源码包随 Release 发布）。
const sourceRepositoryUrl = 'https://github.com/Shiroha23/Tsumugi';
const releasesUrl = '$sourceRepositoryUrl/releases';

const _legalese =
    'Copyright © Tsumugi contributors\n'
    '本程序是自由软件，按 GNU 通用公共许可证第 3 版或（按你的选择）任何更新版本'
    '（GPL-3.0-or-later）发布，不提供任何担保。';

/// 应用版本，如 `0.1.0+1`。
final appVersionProvider = FutureProvider<String>((ref) async {
  final info = await PackageInfo.fromPlatform();
  return info.buildNumber.isEmpty
      ? info.version
      : '${info.version}+${info.buildNumber}';
});

/// 「关于」页：版本、GPL-3.0 声明、源码地址与第三方许可证（architecture §6.4.1）。
class AboutPage extends ConsumerWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final version = ref.watch(appVersionProvider).value;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('关于')),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Tsumugi', style: theme.textTheme.headlineSmall),
                const SizedBox(height: 4),
                Text(
                  '版本 ${version ?? '…'}',
                  key: const ValueKey('about-version'),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
                Text(_legalese, style: theme.textTheme.bodyMedium),
              ],
            ),
          ),
          const Divider(),
          const _LinkTile(
            icon: Icons.code,
            title: '源码仓库',
            url: sourceRepositoryUrl,
          ),
          const _LinkTile(
            icon: Icons.inventory_2_outlined,
            title: '发布与原生组件源码包',
            subtitle: '每个版本的 Release 附有 libmpv / FFmpeg 等原生组件的对应源码',
            url: releasesUrl,
          ),
          ListTile(
            leading: const Icon(Icons.description_outlined),
            title: const Text('第三方许可证'),
            subtitle: const Text('Dart 包、Flutter 引擎与原生组件'),
            onTap: () => showLicensePage(
              context: context,
              applicationName: 'Tsumugi',
              applicationVersion: version,
              applicationLegalese: _legalese,
            ),
          ),
        ],
      ),
    );
  }
}

/// 显示地址并可复制（不引入打开外部链接的依赖）。
class _LinkTile extends StatelessWidget {
  const _LinkTile({
    required this.icon,
    required this.title,
    required this.url,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final String url;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [SelectableText(url), if (subtitle != null) Text(subtitle!)],
      ),
      trailing: IconButton(
        tooltip: '复制地址',
        icon: const Icon(Icons.copy),
        onPressed: () async {
          await Clipboard.setData(ClipboardData(text: url));
          if (!context.mounted) return;
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('已复制')));
        },
      ),
    );
  }
}
