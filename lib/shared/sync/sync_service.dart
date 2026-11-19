import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart' show HttpClientAdapter;

import '../../sources/registry/installed_source.dart';
import '../../sources/registry/source_registry.dart';
import 'credential_store.dart';
import 'sync_document.dart';
import 'sync_exception.dart';
import 'sync_store.dart';
import 'webdav_client.dart';

/// 创建 WebDAV 客户端（测试中接到 mock 服务器）。
typedef WebDavClientFactory = WebDavClient Function(WebDavConfig config);

WebDavClient defaultWebDavClient(WebDavConfig config) => WebDavClient(config);

/// 已保存的密码是否适用于 [server] / [username]：协议、主机、端口与用户名都相同。
bool sameCredentialScope(
  String? savedUrl,
  String? savedUser,
  Uri server,
  String username,
) {
  final saved = savedUrl == null ? null : Uri.tryParse(savedUrl);
  return saved != null &&
      savedUser == username &&
      saved.scheme == server.scheme &&
      saved.host.toLowerCase() == server.host.toLowerCase() &&
      saved.port == server.port;
}

/// 412 后重新下载、合并、再写的最多次数（architecture §4.6）。
const maxConflictRetries = 3;

/// 一次成功同步的摘要。
final class SyncSummary {
  const SyncSummary({
    required this.uploaded,
    required this.localChanges,
    required this.pendingSources,
  });

  /// 是否写入了远端文件。
  final bool uploaded;

  /// 写回本地的记录数。
  final int localChanges;

  /// 待用户确认的源数量（不含已忽略的）。
  final int pendingSources;
}

/// WebDAV 同步（architecture §4.6）：下载 → 合并 → 写本地 → 上传；同时只有一个同步在进行。
class SyncService {
  SyncService({
    required this.store,
    required this.credentials,
    required this.registry,
    WebDavClientFactory? clientFactory,
    DateTime Function()? clock,
  }) : _clientFactory = clientFactory ?? defaultWebDavClient,
       _clock = clock ?? DateTime.now;

  final SyncStore store;
  final CredentialStore credentials;
  final SourceRegistry registry;
  final WebDavClientFactory _clientFactory;
  final DateTime Function() _clock;

  Future<void>? _running;
  final _runningController = StreamController<bool>.broadcast();

  /// 是否有同步正在进行。
  bool get isRunning => _running != null;

  Stream<bool> get runningChanges => _runningController.stream;

  void dispose() => _runningController.close();

  /// 串行执行 [action]：等前一个同步 / 待安装操作结束后再开始。
  Future<T> _exclusive<T>(Future<T> Function() action) async {
    for (var r = _running; r != null; r = _running) {
      await r;
    }
    final done = Completer<void>();
    _running = done.future;
    _runningController.add(true);
    try {
      return await action();
    } finally {
      _running = null;
      done.complete();
      if (!_runningController.isClosed) _runningController.add(false);
    }
  }

  /// 读取当前配置；未配置或缺少密码时抛出 [SyncException]。
  Future<WebDavConfig> _config() async {
    final state = await store.ensureState();
    final url = state.serverUrl;
    final user = state.username;
    if (url == null || user == null) {
      throw const SyncException(SyncError.invalidConfig, '尚未配置 WebDAV 服务器');
    }
    final password = await credentials.readPassword();
    if (password == null) {
      throw const SyncException(SyncError.invalidConfig, '没有保存密码，请重新填写');
    }
    return WebDavConfig(
      serverUrl: url,
      username: user,
      password: password,
      remoteDir: state.remoteDir ?? defaultRemoteDir,
    );
  }

  /// 保存服务器配置与密码。地址、用户名或目录变化时按从未同步处理。
  ///
  /// [password] 为 null 时保留原密码，但只限服务器（协议、主机、端口）与用户名都没变：已保存的密码不会被发给新的主机。
  Future<void> configure({
    required String serverUrl,
    required String username,
    required String remoteDir,
    String? password,
  }) async {
    final uri = parseServerUrl(serverUrl);
    final dir = formatRemoteDir(parseRemoteDir(remoteDir));
    if (username.isEmpty) {
      throw const SyncException(SyncError.invalidConfig, '请填写用户名');
    }
    await _exclusive(() async {
      final old = await store.ensureState();
      final sameScope = sameCredentialScope(
        old.serverUrl,
        old.username,
        uri,
        username,
      );
      if (password == null && !sameScope) {
        throw const SyncException(
          SyncError.invalidConfig,
          '更换了服务器或用户名，请重新填写密码',
        );
      }
      // 先删掉不再适用的旧密码，再保存配置，最后写新密码：任何一步失败都不会让旧密码配上新主机。
      if (!sameScope) await credentials.writePassword(null);
      await store.saveConfig(
        serverUrl: uri.toString(),
        username: username,
        remoteDir: dir,
      );
      if (password != null) await credentials.writePassword(password);
    });
  }

  /// 删除服务器配置与密码，并停用自动同步。
  Future<void> clearConfig() => _exclusive(() async {
    await credentials.writePassword(null);
    await store.saveConfig(
      serverUrl: null,
      username: null,
      remoteDir: null,
      enabled: false,
    );
  });

  /// 测试连接（[config] 为 null 时用已保存的配置）。
  Future<void> testConnection([WebDavConfig? config]) async {
    final client = _clientFactory(config ?? await _config());
    try {
      await client.checkConnection();
    } finally {
      client.close();
    }
  }

  /// 立即同步一次。失败时把错误记入状态（设置页显示）并抛出 [SyncException]。
  Future<SyncSummary> sync() => _exclusive(() async {
    final attemptAt = _clock().millisecondsSinceEpoch;
    try {
      return await _sync(attemptAt);
    } on SyncException catch (e) {
      await store.recordFailure(e.message, attemptAt: attemptAt);
      rethrow;
    } catch (e) {
      final error = SyncException(SyncError.server, '同步失败：$e');
      await store.recordFailure(error.message, attemptAt: attemptAt);
      throw error;
    }
  });

  Future<SyncSummary> _sync(int attemptAt) async {
    final config = await _config();
    final client = _clientFactory(config);
    try {
      for (var attempt = 0; ; attempt++) {
        final state = await store.ensureState();
        final cached = state.remoteSnapshot;
        final etag = state.remoteEtag;
        final got = await client.get(
          ifNoneMatch: etag != null && cached != null ? etag : null,
        );
        final Uint8List? remoteBytes;
        final String? remoteEtag;
        switch (got) {
          case WebDavFile(:final bytes, etag: final e):
            remoteBytes = bytes;
            remoteEtag = e;
          case WebDavNotModified():
            remoteBytes = cached;
            remoteEtag = etag;
          case WebDavNotFound():
            remoteBytes = null;
            remoteEtag = null;
        }
        final remote = remoteBytes == null
            ? null
            : SyncDocument.decode(remoteBytes);
        // 远端文件存在却没有 ETag：无法做条件写入。
        final unsupported = remote != null && remoteEtag == null;

        final applied = await store.mergeAndApply(
          remote,
          trustAbsence: !unsupported,
        );
        final pendingCount = applied.pending.where((p) => !p.dismissed).length;
        final syncedAt = applied.snapshotAt - 1;
        if (remote != null && !applied.result.remoteChanged) {
          await store.recordSuccess(
            lastSyncAt: syncedAt,
            etag: remoteEtag,
            snapshot: remoteBytes,
            conditionalUnsupported: unsupported,
            attemptAt: attemptAt,
          );
          return SyncSummary(
            uploaded: false,
            localChanges: applied.result.localChanges.length,
            pendingSources: pendingCount,
          );
        }

        final doc = SyncDocument(
          collections: applied.result.merged,
          unknownCollections: remote?.unknownCollections ?? const {},
          extra: remote?.extra ?? const {},
        );
        final bytes = doc.encode();
        try {
          if (remote == null) await client.ensureDirectory();
          final newEtag = await client.put(
            bytes,
            ifMatch: remote == null ? null : remoteEtag,
            createOnly: remote == null,
          );
          await store.recordSuccess(
            lastSyncAt: syncedAt,
            etag: newEtag,
            snapshot: bytes,
            conditionalUnsupported: unsupported,
            attemptAt: attemptAt,
          );
          return SyncSummary(
            uploaded: true,
            localChanges: applied.result.localChanges.length,
            pendingSources: pendingCount,
          );
        } on WebDavPreconditionFailed {
          if (attempt >= maxConflictRetries) {
            throw const SyncException(
              SyncError.conflict,
              '其他设备正在同步，多次重试后仍冲突，请稍后再试',
            );
          }
          // 期间有别的设备写入：重新下载、合并、再写（本地已写回的合并结果会参与下一轮合并）。
        }
      }
    } finally {
      client.close();
    }
  }

  /// 预览待安装的源（与本地导入相同的检查，见 `SourceRegistry.prepareImport`）。
  Future<ImportPreview> preparePending(PendingSource pending) =>
      registry.prepareImport(pending.manifest, origin: pending.origin);

  /// 用户确认后安装待安装的源，并写入远端的启用 / 排序 / 设置。
  Future<InstalledSource> installPending(
    PendingSource pending,
    ImportPreview preview,
  ) => _exclusive(() async {
    final installed = await registry.install(preview);
    await store.completePendingInstall(pending);
    return installed;
  });

  Future<void> dismissPending(PendingSource pending, {bool dismissed = true}) =>
      store.setPendingDismissed(pending.id, dismissed);
}

/// 测试注入 HTTP 适配器用。
WebDavClientFactory webDavClientWithAdapter(
  HttpClientAdapter Function() adapter,
) =>
    (config) => WebDavClient(config, adapter: adapter());
