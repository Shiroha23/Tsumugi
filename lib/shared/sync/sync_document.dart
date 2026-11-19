import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:typed_data';

import 'sync_exception.dart';
import 'webdav_client.dart' show maxSyncFileBytes;

/// 本客户端读写的 `syncVersion`。
const supportedSyncVersion = 1;

/// 参与同步的集合与各自主键的段数（architecture §4.6）。
abstract final class SyncCollections {
  static const library = 'library';
  static const itemProgress = 'itemProgress';
  static const unitProgress = 'unitProgress';
  static const sources = 'sources';
  static const repositories = 'repositories';

  static const keyLengths = {
    library: 2,
    itemProgress: 2,
    unitProgress: 3,
    sources: 1,
    repositories: 1,
  };
}

/// 一条同步记录：一行数据或一个墓碑（[deleted]，没有 [data]）。
final class SyncRecord {
  const SyncRecord({
    required this.key,
    required this.modifiedAt,
    required this.deviceId,
    this.deleted = false,
    this.data,
    this.extra = const {},
  });

  const SyncRecord.tombstone({
    required this.key,
    required this.modifiedAt,
    required this.deviceId,
  }) : deleted = true,
       data = null,
       extra = const {};

  final List<String> key;

  /// UTC 毫秒。
  final int modifiedAt;
  final String deviceId;
  final bool deleted;
  final Map<String, Object?>? data;

  /// 记录顶层的未知字段（更高版本客户端写入），原样写回。
  final Map<String, Object?> extra;

  String get keyString => jsonEncode(key);

  SyncRecord withDevice(String id) => copyWith(deviceId: id);

  SyncRecord copyWith({
    int? modifiedAt,
    String? deviceId,
    Map<String, Object?>? data,
    Map<String, Object?>? extra,
  }) => SyncRecord(
    key: key,
    modifiedAt: modifiedAt ?? this.modifiedAt,
    deviceId: deviceId ?? this.deviceId,
    deleted: deleted,
    data: data ?? this.data,
    extra: extra ?? this.extra,
  );

  Map<String, Object?> toJson() => {
    ...extra,
    'key': key,
    'modifiedAt': modifiedAt,
    'deviceId': deviceId,
    'deleted': deleted,
    if (!deleted) 'data': data,
  };

  /// 解析一条记录；结构不合法（主键段数不对、缺时间或设备）时返回 null。
  static SyncRecord? tryParse(Object? json, int keyLength) {
    if (json is! Map) return null;
    final key = json['key'];
    final modifiedAt = json['modifiedAt'];
    final deviceId = json['deviceId'];
    final deleted = json['deleted'] ?? false;
    final data = json['data'];
    if (key is! List ||
        key.length != keyLength ||
        key.any((k) => k is! String) ||
        modifiedAt is! int ||
        modifiedAt < 0 ||
        deviceId is! String ||
        deviceId.isEmpty ||
        deleted is! bool ||
        (!deleted && data is! Map<String, Object?>)) {
      return null;
    }
    return SyncRecord(
      key: key.cast<String>(),
      modifiedAt: modifiedAt,
      deviceId: deviceId,
      deleted: deleted,
      data: deleted ? null : data as Map<String, Object?>,
      extra: {
        for (final MapEntry(:key, :value) in json.entries)
          if (!_recordFields.contains(key)) '$key': value,
      },
    );
  }

  static const _recordFields = {
    'key',
    'modifiedAt',
    'deviceId',
    'deleted',
    'data',
  };
}

/// 远端 `sync-v1.json` 的内容。
final class SyncDocument {
  SyncDocument({
    required this.collections,
    this.unknownCollections = const {},
    this.extra = const {},
    this.hadInvalidRecords = false,
  });

  /// 已知集合：集合名 → 主键字符串 → 记录。
  final Map<String, Map<String, SyncRecord>> collections;

  /// 不认识的集合，原样保留。
  final Map<String, Object?> unknownCollections;

  /// 文件顶层的未知字段。
  final Map<String, Object?> extra;

  /// 解析时丢弃过结构不合法或重复的记录（写回的内容会与远端不同）。
  final bool hadInvalidRecords;

  /// 解压并解析远端文件。
  static SyncDocument decode(List<int> compressed) =>
      fromJson(_decodeJson(gunzipLimited(compressed)));

  static Object? _decodeJson(Uint8List bytes) {
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw const SyncException(SyncError.badFormat, '远端同步文件不是有效的 JSON');
    }
    if (jsonDepth(json) > maxSyncJsonDepth) {
      // 未知字段会原样写回，过深的嵌套会让之后的编码 / 比较栈溢出。
      throw const SyncException(SyncError.badFormat, '远端同步文件嵌套过深');
    }
    return json;
  }

  static SyncDocument fromJson(Object? json) {
    if (json is! Map) {
      throw const SyncException(SyncError.badFormat, '远端同步文件格式错误');
    }
    final version = json['syncVersion'];
    if (version is! int) {
      throw const SyncException(SyncError.badFormat, '远端同步文件缺少 syncVersion');
    }
    if (version > supportedSyncVersion) {
      throw const SyncException(
        SyncError.unsupportedVersion,
        '远端同步文件来自更新版本的客户端，请先更新 Tsumugi',
      );
    }
    final raw = json['collections'];
    if (raw is! Map) {
      throw const SyncException(SyncError.badFormat, '远端同步文件格式错误');
    }
    var invalid = false;
    final collections = <String, Map<String, SyncRecord>>{};
    final unknown = <String, Object?>{};
    for (final MapEntry(:key, :value) in raw.entries) {
      final name = '$key';
      final keyLength = SyncCollections.keyLengths[name];
      if (keyLength == null) {
        unknown[name] = value;
        continue;
      }
      if (value is! List) {
        invalid = true;
        continue;
      }
      final records = <String, SyncRecord>{};
      for (final item in value) {
        final r = SyncRecord.tryParse(item, keyLength);
        if (r == null) {
          invalid = true;
          continue;
        }
        final old = records[r.keyString];
        if (old != null) {
          invalid = true;
          if (!recordWins(r, old)) continue;
        }
        records[r.keyString] = r;
      }
      collections[name] = records;
    }
    return SyncDocument(
      collections: collections,
      unknownCollections: unknown,
      extra: {
        for (final MapEntry(:key, :value) in json.entries)
          if (key != 'syncVersion' && key != 'collections') '$key': value,
      },
      hadInvalidRecords: invalid,
    );
  }

  Map<String, Object?> toJson() => {
    ...extra,
    'syncVersion': supportedSyncVersion,
    'collections': {
      ...unknownCollections,
      for (final MapEntry(:key, :value) in collections.entries)
        key: [for (final k in value.keys.toList()..sort()) value[k]!.toJson()],
    },
  };

  /// 编码并压缩；解压后超过 20 MiB 时抛出 [SyncException]。
  Uint8List encode() {
    final bytes = utf8.encode(jsonEncode(toJson()));
    if (bytes.length > maxSyncFileBytes) {
      throw const SyncException(SyncError.tooLarge, '要同步的数据超过 20 MiB');
    }
    return Uint8List.fromList(gzip.encode(bytes));
  }
}

/// 远端 JSON 允许的最大嵌套深度。
const maxSyncJsonDepth = 64;

/// [value] 的嵌套深度（标量为 0），不递归，深度很大时也不会栈溢出。
int jsonDepth(Object? value) {
  var max = 0;
  final stack = <(Object?, int)>[(value, 0)];
  while (stack.isNotEmpty) {
    final (v, d) = stack.removeLast();
    if (d > max) max = d;
    if (max > maxSyncJsonDepth) return max;
    if (v is Map) {
      for (final e in v.values) {
        stack.add((e, d + 1));
      }
    } else if (v is List) {
      for (final e in v) {
        stack.add((e, d + 1));
      }
    }
  }
  return max;
}

/// 两条同主键记录中 [a] 是否胜出：`modifiedAt` 大者胜，相同时 `deviceId` 字典序大者胜。
bool recordWins(SyncRecord a, SyncRecord b) {
  if (a.modifiedAt != b.modifiedAt) return a.modifiedAt > b.modifiedAt;
  return a.deviceId.compareTo(b.deviceId) > 0;
}

/// gzip 解压，输出超过 [limit] 字节时停止并抛出 [SyncException]。
Uint8List gunzipLimited(List<int> compressed, {int limit = maxSyncFileBytes}) {
  if (compressed.length < 2 || compressed[0] != 0x1f || compressed[1] != 0x8b) {
    throw const SyncException(SyncError.badFormat, '远端同步文件不是 gzip 格式');
  }
  final sink = _LimitedSink(limit);
  try {
    final input = gzip.decoder.startChunkedConversion(sink);
    const step = 64 * 1024;
    for (var i = 0; i < compressed.length; i += step) {
      input.add(
        compressed.sublist(
          i,
          i + step > compressed.length ? compressed.length : i + step,
        ),
      );
    }
    input.close();
  } on SyncException {
    rethrow;
  } catch (_) {
    throw const SyncException(SyncError.badFormat, '远端同步文件已损坏');
  }
  return sink.takeBytes();
}

class _LimitedSink implements Sink<List<int>> {
  _LimitedSink(this.limit);

  final int limit;
  final _out = BytesBuilder(copy: false);

  @override
  void add(List<int> data) {
    if (_out.length + data.length > limit) {
      throw const SyncException(SyncError.tooLarge, '远端同步文件解压后超过 20 MiB');
    }
    _out.add(data);
  }

  @override
  void close() {}

  Uint8List takeBytes() => _out.takeBytes();
}

/// 规范化的 JSON（对象按键排序），用于比较记录内容是否相同。
String canonicalJson(Object? value) => jsonEncode(_canonical(value));

Object? _canonical(Object? v) => switch (v) {
  final Map<dynamic, dynamic> m => {
    for (final k in m.keys.map((k) => '$k').toList()..sort())
      k: _canonical(m[k]),
  },
  final List<dynamic> l => [for (final e in l) _canonical(e)],
  _ => v,
};
