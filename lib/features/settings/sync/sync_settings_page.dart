import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/sync/providers.dart';
import '../../../shared/sync/webdav_client.dart';
import 'pending_source_dialog.dart';

/// 设置 → WebDAV 同步（architecture §4.6）：服务器配置、立即同步、自动同步开关、最近的错误、待安装的源。
class SyncSettingsPage extends ConsumerWidget {
  const SyncSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(syncStatusProvider).value ?? const SyncStatus();
    return Scaffold(
      appBar: AppBar(title: const Text('WebDAV 同步')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          _ServerForm(status: status),
          const Divider(),
          if (status.configured) ...[
            _SyncControls(status: status),
            if (status.pending.isNotEmpty) ...[
              const Divider(),
              _PendingSources(status: status),
            ],
            const Divider(),
          ],
          const _Notice(),
        ],
      ),
    );
  }
}

class _ServerForm extends ConsumerStatefulWidget {
  const _ServerForm({required this.status});

  final SyncStatus status;

  @override
  ConsumerState<_ServerForm> createState() => _ServerFormState();
}

class _ServerFormState extends ConsumerState<_ServerForm> {
  late final _url = TextEditingController(text: widget.status.serverUrl);
  late final _user = TextEditingController(text: widget.status.username);
  final _password = TextEditingController();
  late final _dir = TextEditingController(
    text: widget.status.configured ? widget.status.remoteDir : defaultRemoteDir,
  );
  bool _busy = false;
  String? _message;
  bool _messageIsError = false;
  bool _seeded = false;

  @override
  void didUpdateWidget(_ServerForm old) {
    super.didUpdateWidget(old);
    // 状态首次从数据库读到时填入表单（页面打开时 stream 可能还没有值）。
    if (!_seeded && widget.status.configured && _url.text.isEmpty) {
      _seeded = true;
      _url.text = widget.status.serverUrl ?? '';
      _user.text = widget.status.username ?? '';
      _dir.text = widget.status.remoteDir ?? '';
    }
  }

  @override
  void dispose() {
    _url.dispose();
    _user.dispose();
    _password.dispose();
    _dir.dispose();
    super.dispose();
  }

  SyncService get _service => ref.read(syncServiceProvider);

  Future<void> _run(Future<String> Function() action) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final ok = await action();
      if (mounted) {
        setState(() {
          _message = ok;
          _messageIsError = false;
        });
      }
    } on SyncException catch (e) {
      if (mounted) {
        setState(() {
          _message = e.message;
          _messageIsError = true;
        });
      }
    } catch (e) {
      // 例如系统安全存储读写失败（PlatformException）。
      if (mounted) {
        setState(() {
          _message = '操作失败：$e';
          _messageIsError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 表单中的配置；密码留空且已有配置时沿用已保存的密码。
  Future<WebDavConfig> _formConfig() async {
    var password = _password.text;
    // 已保存的密码只用于同一服务器与用户名，不发给新填的主机。
    if (password.isEmpty &&
        sameCredentialScope(
          widget.status.serverUrl,
          widget.status.username,
          parseServerUrl(_url.text),
          _user.text.trim(),
        )) {
      password = await ref.read(credentialStoreProvider).readPassword() ?? '';
    }
    return WebDavConfig(
      serverUrl: _url.text,
      username: _user.text.trim(),
      password: password,
      remoteDir: _dir.text,
    );
  }

  void _test() => _run(() async {
    await _service.testConnection(await _formConfig());
    return '连接成功';
  });

  void _save() => _run(() async {
    await _service.configure(
      serverUrl: _url.text,
      username: _user.text.trim(),
      remoteDir: _dir.text,
      password: _password.text.isEmpty ? null : _password.text,
    );
    _password.clear();
    final saved = parseServerUrl(_url.text).toString();
    _url.text = saved;
    _dir.text = formatRemoteDir(parseRemoteDir(_dir.text));
    return '已保存';
  });

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除同步配置？'),
        content: const Text('将删除服务器地址、用户名与保存的密码，并停止自动同步。本机与服务器上的数据都不会被删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _run(() async {
      await _service.clearConfig();
      _url.clear();
      _user.clear();
      _password.clear();
      _dir.text = defaultRemoteDir;
      return '已删除同步配置';
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final configured = widget.status.configured;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('服务器', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('sync-url'),
            controller: _url,
            enabled: !_busy,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'WebDAV 地址',
              hintText: 'https://dav.example.com/remote.php/dav/files/me/',
              helperText: '只支持 https',
            ),
          ),
          TextField(
            key: const ValueKey('sync-user'),
            controller: _user,
            enabled: !_busy,
            decoration: const InputDecoration(labelText: '用户名'),
          ),
          TextField(
            key: const ValueKey('sync-password'),
            controller: _password,
            enabled: !_busy,
            obscureText: true,
            decoration: InputDecoration(
              labelText: '密码',
              helperText: configured
                  ? '留空则保留已保存的密码（仅限同一服务器与用户名）'
                  : '保存在系统的安全存储中',
            ),
          ),
          TextField(
            key: const ValueKey('sync-dir'),
            controller: _dir,
            enabled: !_busy,
            decoration: const InputDecoration(labelText: '远端目录'),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                onPressed: _busy ? null : _save,
                child: const Text('保存'),
              ),
              OutlinedButton(
                onPressed: _busy ? null : _test,
                child: const Text('测试连接'),
              ),
              if (configured)
                TextButton(
                  onPressed: _busy ? null : _clear,
                  child: const Text('删除配置'),
                ),
            ],
          ),
          if (_message case final m?) ...[
            const SizedBox(height: 8),
            Text(
              m,
              style: TextStyle(
                color: _messageIsError
                    ? theme.colorScheme.error
                    : theme.colorScheme.primary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

String _formatTime(int ms) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

class _SyncControls extends ConsumerWidget {
  const _SyncControls({required this.status});

  final SyncStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final running = ref.watch(syncRunningProvider).value ?? false;
    final service = ref.read(syncServiceProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          title: const Text('自动同步'),
          subtitle: const Text('启动、回到前台、以及本地有改动后 2 分钟内'),
          value: status.enabled,
          onChanged: (v) => service.store.setEnabled(v),
        ),
        ListTile(
          title: const Text('上次同步'),
          subtitle: Text(
            status.lastSyncAt == null
                ? '尚未同步'
                : _formatTime(status.lastSyncAt!),
          ),
          trailing: FilledButton.tonal(
            onPressed: running
                ? null
                : () async {
                    try {
                      await service.sync();
                    } on SyncException {
                      // 错误显示在下方。
                    }
                  },
            child: running
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('立即同步'),
          ),
        ),
        if (status.lastError case final error?)
          ListTile(
            leading: Icon(Icons.error_outline, color: theme.colorScheme.error),
            title: Text(
              error,
              style: TextStyle(color: theme.colorScheme.error),
            ),
            subtitle: status.lastAttemptAt == null
                ? null
                : Text('最近一次尝试：${_formatTime(status.lastAttemptAt!)}'),
          ),
        if (status.conditionalUnsupported)
          const ListTile(
            leading: Icon(Icons.warning_amber),
            title: Text('服务器不支持并发保护'),
            subtitle: Text('服务器没有返回 ETag。多台设备同时同步时，后写入的一方可能覆盖另一方的改动。'),
          ),
      ],
    );
  }
}

class _PendingSources extends ConsumerWidget {
  const _PendingSources({required this.status});

  final SyncStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final service = ref.read(syncServiceProvider);
    final active = status.pending.where((p) => !p.dismissed).toList();
    final dismissed = status.pending.where((p) => p.dismissed).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text('待安装的源', style: theme.textTheme.titleMedium),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Text(
            '其他设备上安装或更新了这些源。同步来的源和本地导入一样，需要你预览确认后才会安装。',
            style: theme.textTheme.bodySmall,
          ),
        ),
        for (final p in active)
          ListTile(
            title: Text(p.name),
            subtitle: Text('${p.isUpdate ? '更新' : '新源'} · ${p.version}'),
            trailing: Wrap(
              spacing: 4,
              children: [
                TextButton(
                  onPressed: () => service.dismissPending(p),
                  child: const Text('忽略'),
                ),
                FilledButton.tonal(
                  onPressed: () => showPendingSourceDialog(context, p),
                  child: const Text('预览'),
                ),
              ],
            ),
          ),
        for (final p in dismissed)
          ListTile(
            enabled: false,
            title: Text(p.name),
            subtitle: Text('已忽略 · ${p.version}'),
            trailing: TextButton(
              onPressed: () => service.dismissPending(p, dismissed: false),
              child: const Text('恢复'),
            ),
          ),
      ],
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice();

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('同步：书架、阅读进度与历史、已安装的源（清单、设置、启用与排序）、规则仓库订阅。', style: style),
          const SizedBox(height: 4),
          Text('不同步：Cookie 与登录状态、脚本源的存储、已下载的文件、阅读器与播放器偏好。', style: style),
          const SizedBox(height: 4),
          Text(
            '同步文件 sync-v1.json 是压缩的明文 JSON，存放在你自己的服务器上，不加密；'
            '能读取该目录的人都能看到你的书架与阅读记录。密码只保存在本机系统的安全存储中。',
            style: style,
          ),
        ],
      ),
    );
  }
}
