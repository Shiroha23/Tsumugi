import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// 持久化日志回调。
typedef SessionLog = void Function(String message);

/// 一个源会话要持久化的内容（docs/architecture.md §5.3「会话持久化」）。
class SessionSnapshot {
  const SessionSnapshot({this.cookies = const [], this.userAgent});

  final List<StoredCookie> cookies;

  /// WebView 同步来的 User-Agent。
  final String? userAgent;

  bool get isEmpty => cookies.isEmpty && userAgent == null;

  Map<String, Object?> toJson() => {
    'version': SessionPersistence.formatVersion,
    'userAgent': ?userAgent,
    'cookies': [for (final c in cookies) c.toJson()],
  };

  /// 解析文件内容。整体结构不对时抛出 [FormatException]；单个无效的 Cookie 被跳过并记入 [log]。
  factory SessionSnapshot.fromJson(Object? json, {SessionLog? log}) {
    if (json is! Map<String, Object?>) {
      throw const FormatException('session file is not a JSON object');
    }
    final version = json['version'];
    if (version != SessionPersistence.formatVersion) {
      throw FormatException('unsupported session file version: $version');
    }
    final ua = json['userAgent'];
    if (ua != null && ua is! String) {
      throw const FormatException('userAgent is not a string');
    }
    final list = json['cookies'];
    if (list is! List<Object?>) {
      throw const FormatException('cookies is not a list');
    }
    final cookies = <StoredCookie>[];
    for (final item in list) {
      try {
        cookies.add(StoredCookie.fromJson(item));
      } on FormatException catch (e) {
        log?.call('skip invalid cookie: ${e.message}');
      }
    }
    return SessionSnapshot(cookies: cookies, userAgent: ua as String?);
  }
}

/// 持久化的一个 Cookie。只保存属性，不在这里校验名称 / 值（恢复时由 `Cookie` 构造函数校验）。
class StoredCookie {
  const StoredCookie({
    required this.host,
    required this.name,
    required this.value,
    this.domainCookie = false,
    this.path = '/',
    this.expires,
    this.secure = false,
    this.httpOnly = false,
  });

  /// `DateTime` 能表示的最大毫秒数。
  static const _maxEpochMs = 8640000000000000;

  /// 主机限定 Cookie 的主机，或带 Domain 的 Cookie 的域（不含前导点）。
  final String host;

  /// 是否带 Domain 属性（对子域名同样发送）。
  final bool domainCookie;
  final String name;
  final String value;
  final String path;

  /// 绝对过期时间；为 null 表示会话 Cookie。
  final DateTime? expires;
  final bool secure;
  final bool httpOnly;

  Map<String, Object?> toJson() => {
    'host': host,
    if (domainCookie) 'domainCookie': true,
    'name': name,
    'value': value,
    'path': path,
    'expires': ?expires?.toUtc().millisecondsSinceEpoch,
    if (secure) 'secure': true,
    if (httpOnly) 'httpOnly': true,
  };

  factory StoredCookie.fromJson(Object? json) {
    if (json is! Map<String, Object?>) {
      throw const FormatException('cookie is not a JSON object');
    }
    T field<T>(String key, T fallback) {
      final v = json[key];
      if (v == null) return fallback;
      if (v is T) return v as T;
      throw FormatException('cookie field `$key` has wrong type');
    }

    final host = field<String>('host', '');
    final name = field<String>('name', '');
    if (host.isEmpty || name.isEmpty) {
      throw const FormatException('cookie without host or name');
    }
    final expires = field<int?>('expires', null);
    if (expires != null && expires.abs() > _maxEpochMs) {
      throw const FormatException('cookie expires out of range');
    }
    return StoredCookie(
      host: host,
      domainCookie: field<bool>('domainCookie', false),
      name: name,
      value: field<String>('value', ''),
      path: field<String>('path', '/'),
      expires: expires == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(expires, isUtc: true),
      secure: field<bool>('secure', false),
      httpOnly: field<bool>('httpOnly', false),
    );
  }
}

/// 把每个源的会话存为一个 JSON 文件（docs/architecture.md §5.3「会话持久化」）。
///
/// - 文件：`<目录>/<sourceId 的 sha256>.json`；一个源只读写自己的文件。
/// - 同一源的加载、写入、删除在一个队列中串行执行；写入先写临时文件再重命名替换。
/// - 文件损坏时删除并记录日志，按空会话处理；IO 失败只记录日志，不向调用方抛出。
class SessionPersistence {
  SessionPersistence(Future<Directory> Function() directory, {SessionLog? log})
    : _resolveDirectory = directory,
      _log = log ?? _ignore;

  /// 使用固定目录（测试用）。
  SessionPersistence.at(Directory directory, {SessionLog? log})
    : this(() async => directory, log: log);

  static const formatVersion = 1;
  static const _ext = '.json';
  static const _tmpExt = '.json.tmp';

  final Future<Directory> Function() _resolveDirectory;
  final SessionLog _log;
  Future<Directory>? _directory;
  final _queues = <String, Future<void>>{};

  static void _ignore(String _) {}

  /// [sourceId] 对应的文件名（不含目录）：UTF-8 字节的 sha256 小写十六进制 + `.json`。
  ///
  /// 定长（69 个字符），不受 sourceId 长度影响，也避开 `..`、Windows 保留名与大小写问题。
  static String fileNameFor(String sourceId) => '${_key(sourceId)}$_ext';

  /// 文件与队列的键。
  static String _key(String sourceId) =>
      sha256.convert(utf8.encode(sourceId)).toString();

  /// 文件名是否为本类生成的会话文件（或其临时文件）；返回其键，否则返回 null。
  static String? _keyOfFile(String fileName) {
    final match = _filePattern.firstMatch(fileName);
    return match?.group(1);
  }

  static final _filePattern = RegExp(r'^([0-9a-f]{64})\.json(\.tmp)?$');

  Future<Directory> _dir() => _directory ??= _resolveDirectory().then(
    (d) => d,
    onError: (Object e) {
      _directory = null; // 下次重试
      throw e;
    },
  );

  Future<File> _file(String sourceId, [String ext = _ext]) =>
      _fileOfKey(_key(sourceId), ext);

  Future<File> _fileOfKey(String key, [String ext = _ext]) async {
    final dir = await _dir();
    return File('${dir.path}${Platform.pathSeparator}$key$ext');
  }

  /// 在 [sourceId] 的队列中执行 [op]；[op] 的异常传给返回的 Future，但不影响队列中后续操作。
  Future<T> _enqueue<T>(String sourceId, Future<T> Function() op) =>
      _enqueueKey(_key(sourceId), op);

  Future<T> _enqueueKey<T>(String key, Future<T> Function() op) {
    final previous = _queues[key] ?? Future<void>.value();
    final result = previous.then((_) => op());
    final tail = result.then<void>((_) {}, onError: (Object _) {});
    _queues[key] = tail;
    tail.whenComplete(() {
      if (identical(_queues[key], tail)) _queues.remove(key);
    }).ignore();
    return result;
  }

  /// 读取 [sourceId] 的会话并在队列内交给 [apply]（之后排队的写入一定在 [apply] 之后执行）。
  /// 没有文件、文件损坏或读取失败时不调用 [apply]。
  Future<void> load(String sourceId, void Function(SessionSnapshot) apply) =>
      _enqueue(sourceId, () async {
        final SessionSnapshot? snapshot;
        try {
          snapshot = await _read(sourceId);
        } on Object catch (e) {
          _log('[$sourceId] load session failed: $e');
          return;
        }
        if (snapshot != null) apply(snapshot);
      });

  Future<SessionSnapshot?> _read(String sourceId) async {
    final file = await _file(sourceId);
    final String text;
    try {
      text = await file.readAsString();
    } on PathNotFoundException {
      return null;
    }
    try {
      return SessionSnapshot.fromJson(
        jsonDecode(text),
        log: (m) => _log('[$sourceId] $m'),
      );
    } on FormatException catch (e) {
      _log('[$sourceId] discard corrupt session file: ${e.message}');
      await _deleteFile(file);
      return null;
    }
  }

  /// 排队写入 [sourceId] 的会话。[snapshot] 在轮到这次写入时才调用，因此总是写入最新状态；
  /// 返回 null 表示放弃这次写入（如会话已关闭），返回空快照时删除文件。
  Future<void> write(String sourceId, SessionSnapshot? Function() snapshot) =>
      _enqueue(sourceId, () async {
        try {
          final data = snapshot();
          if (data == null) return;
          if (data.isEmpty) {
            await _deleteFile(await _file(sourceId));
          } else {
            await _writeAtomically(sourceId, jsonEncode(data.toJson()));
          }
        } on Object catch (e) {
          _log('[$sourceId] save session failed: $e');
        }
      });

  Future<void> _writeAtomically(String sourceId, String text) async {
    final dir = await _dir();
    await dir.create(recursive: true);
    final tmp = await _file(sourceId, _tmpExt);
    await tmp.writeAsString(text, flush: true);
    await tmp.rename((await _file(sourceId)).path);
  }

  /// 排队删除 [sourceId] 的会话文件。
  Future<void> delete(String sourceId) => _enqueue(sourceId, () async {
    try {
      await _deleteFile(await _file(sourceId));
      await _deleteFile(await _file(sourceId, _tmpExt));
    } on Object catch (e) {
      _log('[$sourceId] delete session failed: $e');
    }
  });

  /// 删除不属于 [keep] 返回的任何源的会话文件，并清理残留的临时文件；不认识的文件不碰。
  ///
  /// [keep] 在每个文件的队列中、真正删除前才求值，因此列目录期间新安装并写入的源不会被误删。
  Future<void> sweep(Iterable<String> Function() keep) async {
    final List<FileSystemEntity> entries;
    try {
      final dir = await _dir();
      if (!await dir.exists()) return;
      entries = await dir.list(followLinks: false).toList();
    } on Object catch (e) {
      _log('sweep session files failed: $e');
      return;
    }
    final keys = <String>{
      for (final entry in entries)
        if (entry is File) ?_keyOfFile(entry.uri.pathSegments.last),
    };
    await Future.wait([
      for (final key in keys)
        _enqueueKey(key, () async {
          try {
            // 临时文件只会是上次写入中断留下的（写入在队列内完成），总可以删除。
            await _deleteFile(await _fileOfKey(key, _tmpExt));
            if (!keep().map(_key).contains(key)) {
              await _deleteFile(await _fileOfKey(key));
            }
          } on Object catch (e) {
            _log('sweep session file $key failed: $e');
          }
        }),
    ]);
  }

  /// 等待 [sourceId] 队列中已排队的操作完成（测试用）。
  Future<void> idle(String sourceId) =>
      _queues[_key(sourceId)] ?? Future.value();

  static Future<void> _deleteFile(File file) async {
    try {
      await file.delete();
    } on PathNotFoundException {
      // 已不存在
    }
  }
}
