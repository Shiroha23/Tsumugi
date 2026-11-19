import 'package:tsumugi/core/storage/app_database.dart';
import 'package:tsumugi/shared/history/history_repository.dart';
import 'package:tsumugi/shared/library/library_repository.dart';
import 'package:tsumugi/shared/sync/credential_store.dart';
import 'package:tsumugi/shared/sync/sync_service.dart';
import 'package:tsumugi/shared/sync/sync_store.dart';
import 'package:tsumugi/shared/sync/webdav_client.dart';
import 'package:tsumugi/sources/registry/source_registry.dart';

import '../../core/network/mock_support.dart';
import '../../core/storage/test_database.dart';

export '../../core/network/mock_support.dart';

List<PendingSource> decodePending(SyncStateRow state) =>
    decodePendingSources(state.pendingSourcesJson);

/// mock 服务器上的 WebDAV 地址（回环地址允许 http）。
String davUrl(MockServer server) => '${server.origin}/dav/';

/// 一台“设备”：独立的内存数据库 + 同步服务，经 mock WebDAV 同步。
class TestDevice {
  TestDevice(this.server, {String? password})
    : password = password ?? MockWebDav.password;

  /// 配置时填写的密码。
  final String password;

  final MockServer server;
  final credentials = MemoryCredentialStore();
  final AppDatabase db = openTestDatabase();
  late final store = SyncStore(db);
  late final registry = SourceRegistry(db);
  late final library = LibraryRepository(db);
  late final history = HistoryRepository(db);
  late final service = SyncService(
    store: store,
    credentials: credentials,
    registry: registry,
    clientFactory: (config) =>
        WebDavClient(config, adapter: mockAdapter(server)),
  );

  Future<void> configure({String remoteDir = 'Tsumugi/'}) => service.configure(
    serverUrl: davUrl(server),
    username: MockWebDav.username,
    remoteDir: remoteDir,
    password: password,
  );

  Future<void> close() async {
    service.dispose();
    await db.close();
  }
}
