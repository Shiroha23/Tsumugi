import 'dart:async';

import 'package:drift/drift.dart';

import '../../core/storage/app_database.dart';
import 'sync_service.dart';

/// 本地改动后多久自动同步（architecture §4.6）。
const syncAfterLocalChange = Duration(minutes: 2);

/// 自动同步的触发：应用启动、回到前台、本地改动后 [changeDelay]。只在已启用且已配置服务器时同步；
/// 已有同步在进行时跳过。失败只记入同步状态（设置页显示），不打断阅读。
class SyncScheduler {
  SyncScheduler({
    required this.service,
    required AppDatabase db,
    this.changeDelay = syncAfterLocalChange,
  }) : _db = db; // ignore: prefer_initializing_formals

  final SyncService service;
  final AppDatabase _db;
  final Duration changeDelay;

  StreamSubscription<Set<TableUpdate>>? _changes;
  Timer? _timer;
  bool _disposed = false;

  /// 开始监听本地改动，并按“应用启动”触发一次。
  void start() {
    _changes ??= _db
        .tableUpdates(
          TableUpdateQuery.onAllTables([
            _db.libraryEntries,
            _db.itemProgressEntries,
            _db.unitProgressEntries,
            _db.installedSources,
            _db.sourceRepositories,
          ]),
        )
        .listen((_) => _onLocalChange());
    unawaited(trigger());
  }

  /// 回到前台的触发至少间隔这么久（Windows 上窗口每次获得焦点都算回到前台）。
  static const resumeInterval = Duration(minutes: 1);

  DateTime? _lastResume;

  /// 应用回到前台。
  void onResume() {
    final now = DateTime.now();
    final last = _lastResume;
    if (last != null && now.difference(last) < resumeInterval) return;
    _lastResume = now;
    unawaited(trigger());
  }

  void _onLocalChange() {
    // 不重新计时：持续阅读时也会在第一次改动后 [changeDelay] 内同步。
    if (_timer != null || _disposed) return;
    _timer = Timer(changeDelay, () {
      _timer = null;
      unawaited(_syncIfChanged());
    });
  }

  Future<void> _syncIfChanged() async {
    if (_disposed) return;
    // 已有同步在进行：它的快照可能不含这次改动，等它结束后再检查，不能直接丢掉。
    if (service.isRunning) {
      _timer ??= Timer(_retryDelay, () {
        _timer = null;
        unawaited(_syncIfChanged());
      });
      return;
    }
    // 同步自己写回的合并结果也会触发表更新：只有上次同步后确有本地改动才再同步。
    if (await service.store.hasLocalChanges()) await trigger();
  }

  /// 本地改动到期时恰有同步在进行：隔这么久再检查一次。
  Duration get _retryDelay => changeDelay < const Duration(seconds: 10)
      ? changeDelay
      : const Duration(seconds: 10);

  /// 已启用且已配置时同步一次；返回是否进行了同步。
  Future<bool> trigger() async {
    if (_disposed || service.isRunning) return false;
    final state = await service.store.ensureState();
    if (!state.enabled || state.serverUrl == null) return false;
    try {
      await service.sync();
    } catch (_) {
      // 错误已记入同步状态。
    }
    return true;
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    unawaited(_changes?.cancel());
    _changes = null;
  }
}
