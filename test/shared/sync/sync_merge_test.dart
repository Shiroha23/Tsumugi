import 'package:flutter_test/flutter_test.dart';
import 'package:tsumugi/shared/sync/sync_document.dart';
import 'package:tsumugi/shared/sync/sync_merge.dart';

const _lib = SyncCollections.library;
const _me = 'aaaa';
const _other = 'bbbb';
const _day = 24 * 60 * 60 * 1000;
const _now = 1000 * _day;

SyncRecord _rec(
  String id,
  int modifiedAt, {
  String device = _me,
  String title = 't',
}) => SyncRecord(
  key: ['src', id],
  modifiedAt: modifiedAt,
  deviceId: device,
  data: {'title': title},
);

SyncRecord _tomb(String id, int modifiedAt, {String device = _me}) =>
    SyncRecord.tombstone(
      key: ['src', id],
      modifiedAt: modifiedAt,
      deviceId: device,
    );

Map<String, Map<String, SyncRecord>> _set(List<SyncRecord> records) => {
  _lib: {for (final r in records) r.keyString: r},
};

SyncDocument _doc(List<SyncRecord> records) => SyncDocument(
  collections: {
    for (final c in SyncCollections.keyLengths.keys) c: {},
    ..._set(records),
  },
);

MergeResult _merge({
  List<SyncRecord> local = const [],
  List<SyncRecord>? remote,
  int? lastSyncAt,
  String deviceId = _me,
  // 默认的“现在”很小，小数值的时间不会被当作过期墓碑；过期测试传 [_now]。
  int now = 100,
}) => mergeSync(
  local: _set(local),
  remote: remote == null ? null : _doc(remote),
  lastSyncAt: lastSyncAt,
  now: now,
  deviceId: deviceId,
);

Map<String, SyncRecord> _out(MergeResult r) => r.merged[_lib]!;

String _k(String id) => _rec(id, 0).keyString;

void main() {
  test('union of local and remote; newer modifiedAt wins', () {
    final r = _merge(
      local: [
        _rec('a', 10, title: 'local'),
        _rec('b', 30, title: 'mine'),
      ],
      remote: [
        _rec('a', 20, device: _other, title: 'remote'),
        _rec('b', 25, device: _other, title: 'theirs'),
        _rec('c', 5, device: _other),
      ],
    );
    expect(_out(r).keys, unorderedEquals([_k('a'), _k('b'), _k('c')]));
    expect(_out(r)[_k('a')]!.data!['title'], 'remote');
    expect(_out(r)[_k('b')]!.data!['title'], 'mine');
    // 本地需要写入 a（远端胜出）与 c（远端新增），b 不变。
    expect(
      r.localChanges.map((c) => c.winner!.key[1]),
      unorderedEquals(['a', 'c']),
    );
    expect(r.remoteChanged, isTrue);
  });

  test('tie on modifiedAt is decided by deviceId, same on both devices', () {
    final mine = _rec('a', 10, title: 'from-aaaa');
    final theirs = _rec('a', 10, device: _other, title: 'from-bbbb');
    // 本机 aaaa：远端 bbbb 字典序大，胜出。
    final onA = _merge(local: [mine], remote: [theirs]);
    expect(_out(onA)[_k('a')]!.data!['title'], 'from-bbbb');
    // 本机 bbbb 看到 aaaa 写的远端：本机胜出。结果一致。
    final onB = _merge(
      local: [_rec('a', 10, device: _other, title: 'from-bbbb')],
      remote: [mine],
      deviceId: _other,
    );
    expect(_out(onB)[_k('a')]!.data!['title'], 'from-bbbb');
    expect(_out(onB)[_k('a')]!.deviceId, _other);
    expect(onB.localChanges, isEmpty);
    expect(onB.remoteChanged, isTrue);
  });

  test('same modifiedAt and same content: no change either way', () {
    final r = _merge(
      local: [_rec('a', 10)],
      remote: [_rec('a', 10, device: _other)],
    );
    expect(r.localChanges, isEmpty);
    expect(r.remoteChanged, isFalse);
    // 沿用远端记录（含其 deviceId）。
    expect(_out(r)[_k('a')]!.deviceId, _other);
  });

  test('tombstone beats an older record and loses to a newer one', () {
    final deleted = _merge(
      local: [_rec('a', 10)],
      remote: [_tomb('a', 20, device: _other)],
    );
    expect(_out(deleted)[_k('a')]!.deleted, isTrue);
    expect(deleted.localChanges.single.winner!.deleted, isTrue);

    final readded = _merge(
      local: [_rec('a', 30)],
      remote: [_tomb('a', 20, device: _other)],
    );
    expect(_out(readded)[_k('a')]!.deleted, isFalse);
    expect(readded.localChanges, isEmpty);
    expect(readded.remoteChanged, isTrue);

    final localDelete = _merge(
      local: [_tomb('a', 30)],
      remote: [_rec('a', 20, device: _other)],
    );
    expect(_out(localDelete)[_k('a')]!.deleted, isTrue);
    expect(localDelete.remoteChanged, isTrue);
  });

  group('records missing remotely', () {
    test('unchanged since last sync: treated as deleted elsewhere', () {
      // 长期离线：别的设备删除后墓碑已被清理，远端只是没有这条记录。
      final r = _merge(
        local: [_rec('a', 10), _rec('b', 50)],
        remote: [],
        lastSyncAt: 40,
      );
      expect(_out(r).keys, [_k('b')]);
      final change = r.localChanges.single;
      expect(change.local!.key[1], 'a');
      expect(change.winner, isNull);
    });

    test('modified after last sync: kept and uploaded', () {
      final r = _merge(local: [_rec('a', 41)], remote: [], lastSyncAt: 40);
      expect(_out(r).keys, [_k('a')]);
      expect(r.localChanges, isEmpty);
      expect(r.remoteChanged, isTrue);
    });

    test('never synced: everything is kept', () {
      final r = _merge(local: [_rec('a', 10)], remote: []);
      expect(_out(r).keys, [_k('a')]);
    });

    test('no remote file: everything is kept even with a last sync time', () {
      final r = mergeSync(
        local: _set([_rec('a', 10)]),
        remote: null,
        lastSyncAt: 40,
        now: _now,
        deviceId: _me,
      );
      expect(_out(r).keys, [_k('a')]);
      expect(r.remoteChanged, isTrue);
    });

    test('a collection absent from the remote file counts as never synced', () {
      final r = mergeSync(
        local: _set([_rec('a', 10)]),
        remote: SyncDocument(collections: {}),
        lastSyncAt: 40,
        now: _now,
        deviceId: _me,
      );
      expect(_out(r).keys, [_k('a')]);
    });

    test('a local tombstone already uploaded is dropped', () {
      final r = _merge(local: [_tomb('a', 10)], remote: [], lastSyncAt: 40);
      expect(_out(r), isEmpty);
      expect(r.localChanges.single.winner, isNull);
    });
  });

  test('tombstones older than 90 days are purged on both sides', () {
    final old = _now - 91 * _day;
    final recent = _now - 89 * _day;
    final r = _merge(
      local: [_tomb('a', old)],
      remote: [
        _tomb('b', old, device: _other),
        _tomb('c', recent),
      ],
      now: _now,
    );
    expect(_out(r).keys, [_k('c')]);
    expect(r.remoteChanged, isTrue);
    // 本地墓碑 a 也被清理。
    expect(
      r.localChanges.where((c) => c.winner == null).map((c) => c.key[1]),
      contains('a'),
    );
  });

  test('an expired tombstone still deletes the older local record', () {
    final r = _merge(
      local: [_rec('a', 10)],
      remote: [_tomb('a', _now - 91 * _day, device: _other)],
      now: _now,
    );
    expect(_out(r), isEmpty);
    expect(r.localChanges.single.local!.deleted, isFalse);
    expect(r.localChanges.single.winner, isNull);
  });

  test('remote records far in the future count as now', () {
    // 篡改或时钟严重偏快：远端墓碑的时间远在将来。
    final r = _merge(
      local: [_rec('a', 150)],
      remote: [_tomb('a', 9000000000000000, device: _other)],
      now: 100,
    );
    // 按“现在”（100）比较，本机 150 的修改胜出。
    expect(_out(r)[_k('a')]!.deleted, isFalse);
    expect(r.remoteChanged, isTrue);
    final clamped = _merge(
      local: [_rec('a', 50)],
      remote: [_rec('a', 9000000000000000, device: _other, title: 'x')],
      now: 100,
    );
    expect(_out(clamped)[_k('a')]!.modifiedAt, 100);
  });

  test('resolve hook adjusts the winner when both sides are live', () {
    final r = mergeSync(
      local: _set([_rec('a', 10, title: 'v2')]),
      remote: _doc([_rec('a', 20, device: _other, title: 'v1')]),
      lastSyncAt: null,
      now: 100,
      deviceId: _me,
      resolve: (c, winner, other) => winner.copyWith(data: other.data),
    );
    expect(_out(r)[_k('a')]!.modifiedAt, 20);
    expect(_out(r)[_k('a')]!.data!['title'], 'v2');
  });

  test('unknown record fields survive when the local row wins', () {
    final remote = SyncRecord(
      key: const ['src', 'a'],
      modifiedAt: 10,
      deviceId: _other,
      data: const {'title': 'old'},
      extra: const {'futureField': 1},
    );
    final r = _merge(
      local: [_rec('a', 20, title: 'new')],
      remote: [remote],
    );
    final out = _out(r)[_k('a')]!;
    expect(out.data!['title'], 'new');
    expect(out.toJson()['futureField'], 1);
  });

  test('custom content comparison (sources ignore origin)', () {
    final r = mergeSync(
      local: _set([_rec('a', 10, title: 'x')]),
      remote: _doc([_rec('a', 10, device: _other, title: 'y')]),
      lastSyncAt: null,
      now: _now,
      deviceId: _me,
      sameContent: (c, a, b) => true,
    );
    expect(r.localChanges, isEmpty);
    expect(r.remoteChanged, isFalse);
  });
}
