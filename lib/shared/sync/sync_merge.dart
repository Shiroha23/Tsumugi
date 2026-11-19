import 'sync_document.dart';

/// 墓碑保留时间（architecture §4.6）。
const tombstoneRetention = Duration(days: 90);

/// 远端记录的 `modifiedAt` 最多可以比本机时钟晚这么多；更晚的（篡改或时钟严重偏快）按“现在”处理，
/// 否则一条未来时间的记录或墓碑会永远压过本机的修改。
const maxClockSkew = Duration(days: 1);

/// 两边都有、都不是墓碑时，调整胜出的记录（例如已安装源的清单按版本取高者）。
typedef ResolveWinner = SyncRecord Function(
  String collection,
  SyncRecord winner,
  SyncRecord other,
);

/// 判断同一集合中两条非墓碑记录的内容是否相同（不比较时间与设备）。
typedef SameContent = bool Function(
  String collection,
  SyncRecord a,
  SyncRecord b,
);

/// 默认：`data` 的规范化 JSON 相同。
bool sameData(String collection, SyncRecord a, SyncRecord b) =>
    canonicalJson(a.data) == canonicalJson(b.data);

/// 一个主键的合并结果。
final class KeyMerge {
  const KeyMerge({
    required this.collection,
    required this.local,
    required this.winner,
  });

  final String collection;

  /// 本地原有的记录或墓碑（没有为 null）。
  final SyncRecord? local;

  /// 合并后的记录或墓碑；null 表示两边都不再保留（按删除处理且无需墓碑，或墓碑已过期）。
  final SyncRecord? winner;

  List<String> get key => (winner ?? local)!.key;
}

final class MergeResult {
  const MergeResult({
    required this.merged,
    required this.localChanges,
    required this.remoteChanged,
  });

  /// 合并后的全部记录（含未过期的墓碑），即要写回远端的内容。
  final Map<String, Map<String, SyncRecord>> merged;

  /// 本地需要改动的主键（本地状态与合并结果不同）。
  final List<KeyMerge> localChanges;

  /// 合并结果与远端文件不同，需要写回。
  final bool remoteChanged;
}

/// 按记录合并本地与远端（architecture §4.6）。纯函数，便于测试。
///
/// - [local]：集合名 → 主键字符串 → 本地记录（含本地墓碑），`deviceId` 一律为本机 [deviceId]；
/// - [remote]：远端文件，null 表示远端还没有文件（此时按从未同步处理，本地记录全部保留）；
/// - [lastSyncAt]：上次成功同步的时间，null 表示从未同步。远端没有、且 `modifiedAt` 不晚于它的本地记录按删除处理；
///   远端文件中缺少某个集合时，该集合按从未同步处理；
/// - [now]：用于清理超过 [tombstoneRetention] 的墓碑。
MergeResult mergeSync({
  required Map<String, Map<String, SyncRecord>> local,
  required SyncDocument? remote,
  required int? lastSyncAt,
  required int now,
  required String deviceId,
  SameContent sameContent = sameData,
  ResolveWinner? resolve,
}) {
  final latest = now + maxClockSkew.inMilliseconds;
  final expireBefore = now - tombstoneRetention.inMilliseconds;
  final merged = <String, Map<String, SyncRecord>>{};
  final changes = <KeyMerge>[];
  var remoteChanged = remote == null || remote.hadInvalidRecords;

  bool same(String c, SyncRecord a, SyncRecord b) {
    if (a.deleted || b.deleted) return a.deleted && b.deleted;
    return sameContent(c, a, b);
  }

  for (final collection in SyncCollections.keyLengths.keys) {
    final localRecords = local[collection] ?? const {};
    final remoteRecords = remote?.collections[collection];
    if (remote != null && remoteRecords == null) remoteChanged = true;
    final since = remoteRecords == null ? null : lastSyncAt;
    final out = <String, SyncRecord>{};
    for (final key in {...localRecords.keys, ...?remoteRecords?.keys}) {
      final l = localRecords[key];
      var r = remoteRecords?[key];
      if (r != null && r.modifiedAt > latest) {
        r = r.copyWith(modifiedAt: now);
        remoteChanged = true;
      }
      SyncRecord? winner;
      if (r == null) {
        // 远端没有：上次同步后没改过的，说明已上传后被别处删除（墓碑可能已清理）。
        winner = since != null && l!.modifiedAt <= since ? null : l;
      } else if (l == null) {
        winner = r;
      } else if (l.modifiedAt == r.modifiedAt && same(collection, l, r)) {
        winner = r;
      } else {
        // 本地行没有记录顶层的未知字段（更高版本客户端写入）：沿用远端记录的，免得本机胜出时丢掉。
        final mine = l.copyWith(deviceId: deviceId, extra: r.extra);
        winner = recordWins(mine, r) ? mine : r;
        if (resolve != null && !l.deleted && !r.deleted) {
          winner = resolve(collection, winner, identical(winner, r) ? mine : r);
        }
      }
      if (winner != null &&
          winner.deleted &&
          winner.modifiedAt < expireBefore) {
        winner = null;
      }
      if (winner != null) out[key] = winner;
      if (!identical(winner, r)) remoteChanged = true;
      final localSame =
          identical(winner, l) ||
          (winner != null &&
              l != null &&
              winner.modifiedAt == l.modifiedAt &&
              same(collection, winner, l));
      if (!localSame && !(winner == null && l == null)) {
        changes.add(KeyMerge(collection: collection, local: l, winner: winner));
      }
    }
    merged[collection] = out;
  }
  return MergeResult(
    merged: merged,
    localChanges: changes,
    remoteChanged: remoteChanged,
  );
}
