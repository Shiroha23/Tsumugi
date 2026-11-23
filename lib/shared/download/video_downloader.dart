import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../../core/network/media/aes128.dart';
import '../../core/network/media/hls_download_plan.dart';
import '../../core/network/media/hls_playlist.dart'
    show looksLikeHlsPlaylist, looksLikeWebVtt;
import '../../core/network/media/media_signature.dart';
import '../../core/network/network_exception.dart';
import '../../core/network/source_http_client.dart';
import '../../core/subtitle/subtitle_loader.dart';
import '../../core/subtitle/subtitle_parser.dart';
import '../../sources/model/content.dart';
import '../../sources/source.dart';
import '../video/video_streams.dart';
import 'download_paths.dart';
import 'download_store.dart';
import 'video_manifest.dart';

/// 写入下载目录失败（磁盘满等），对应错误码 `E_STORAGE`（architecture §4.5.1）。
final class DownloadStorageException implements Exception {
  const DownloadStorageException(this.cause);

  final FileSystemException cause;

  @override
  String toString() => 'DownloadStorageException: $cause';
}

/// 视频下载的上限（architecture §4.5.1）。
final class VideoDownloadLimits {
  const VideoDownloadLimits({
    this.maxItems = 20000,
    this.maxBytes = 16 * 1024 * 1024 * 1024,
    this.concurrency = 3,
    this.maxPlaylistBytes = 4 * 1024 * 1024,
    this.maxEncryptedSegmentBytes = 64 * 1024 * 1024,
    this.manifestWriteInterval = 10,
    this.progressInterval = const Duration(milliseconds: 500),
  });

  /// 每个剧集最多的分片数（含初始化分片与字幕分片）。
  final int maxItems;

  /// 每个剧集合计字节上限（HLS 与单文件相同）。
  final int maxBytes;

  /// 每个剧集同时进行的分片请求数。
  final int concurrency;
  final int maxPlaylistBytes;

  /// AES-128 分片整段读入内存解密，沿用代理的上限。
  final int maxEncryptedSegmentBytes;

  /// 每写完多少个分片重写一次 `video.json`。
  final int manifestWriteInterval;

  /// 进度写入数据库的最小间隔。
  final Duration progressInterval;
}

/// 进度回调：已完成的文件数、总文件数、已写入的字节数。
typedef VideoProgress = Future<void> Function(
  int completed,
  int total,
  int bytes,
);

/// 下载一个视频剧集（architecture §4.5.1）：HLS 按分片落盘（AES-128 解密后存明文）+ `video.json`，
/// 单文件整文件下载；外挂字幕按原样保存。所有请求经该源的 [SourceHttpClient.openStream]
/// （白名单与每跳重定向、Cookie、默认 headers、`StreamRef.headers`）：播放列表与外挂字幕计入 `rateLimit`，
/// 分片、密钥与单文件的区间请求计入媒体配额。
///
/// 返回（已完成的文件数、总文件数、字节数）。失败时抛出 [SourceException]、[NetworkException]
/// 或 [DownloadStorageException]；[abort] 取消时进行中的请求立即中止。
class VideoDownloadTask {
  VideoDownloadTask({
    required this.client,
    required this.baseUrl,
    required this.content,
    required this.preferredLabel,
    required this.dir,
    required this.abort,
    required this.onProgress,
    this.limits = const VideoDownloadLimits(),
  });

  final SourceHttpClient client;
  final Uri baseUrl;
  final VideoContent content;

  /// 下载对话框中选择的清晰度标签（[DownloadUnit.streamLabel]）。
  final String? preferredLabel;
  final Directory dir;
  final NetCancellation abort;
  final VideoProgress onProgress;
  final VideoDownloadLimits limits;

  late final StreamRef _stream;
  late final int _streamIndex;
  late final String _label;
  late final Map<String, String> _headers;
  int _bytes = 0;

  Future<(int, int, int)> run() async {
    final streams = playableStreams(content);
    if (streams.isEmpty) {
      throw SourceException(
        SourceErrorCode.unsupported,
        content.streams.isEmpty ? '没有可下载的流' : '暂不支持 DASH',
      );
    }
    _streamIndex = pickStream(streams, preferredLabel);
    _stream = streams[_streamIndex];
    _label = streamLabel(streams, _streamIndex);
    _headers = {
      for (final e in (_stream.headers ?? const {}).entries)
        e.key.toLowerCase(): e.value,
    };
    final Uri root;
    try {
      root = baseUrl.resolve(_stream.url.trim());
    } on FormatException {
      throw const SourceException(SourceErrorCode.parse, '无效的视频地址');
    }

    VideoManifest? existing;
    try {
      existing = await _readManifest();
    } on FormatException {
      existing = null;
    }

    // 单文件续传：只在有校验值、已知总长度且来源标识一致时（§4.5.1「续传」）。
    final fileKey = _key([
      'file',
      _streamIndex,
      _stream.quality,
      strippedHlsUrl(root),
    ]);
    NetStreamResponse? up;
    if (existing?.file case final f?
        when existing!.sourceKey == fileKey &&
            f.validator != null &&
            f.length != null) {
      final media = DownloadStore.fileIn(dir, videoFileName);
      final have = await _length(media);
      if (have > 0 && have < f.length!) {
        final resumed = await _open(
          root,
          lane: RateLimitLane.media,
          extra: {'range': 'bytes=$have-', 'if-range': f.validator!},
        );
        if (resumed.status == HttpStatus.partialContent) {
          final cr = _contentRange(resumed.headers['content-range']);
          if (cr != null && cr.$1 == have && cr.$3 == f.length) {
            return _resumeFile(resumed, existing, have);
          }
          resumed.cancel();
        } else if (resumed.status == HttpStatus.ok) {
          up = resumed; // 上游内容变了（或不支持区间）：按新下载处理
        } else {
          resumed.cancel();
        }
      }
    }
    up ??= await _open(root, lane: RateLimitLane.source);
    _checkStatus(up);
    final (head, rest) = await _peek(up, 1024);
    if (looksLikeHlsPlaylist(head)) {
      final text = await _collectText(head, rest, up);
      return _downloadHls(text, up.url, existing);
    }
    if (!looksLikeMediaContainer(head)) {
      await rest.cancel();
      up.cancel();
      throw const SourceException(SourceErrorCode.parse, '无法识别的视频内容');
    }
    return _downloadFile(up, head, rest, fileKey);
  }

  // ---------------------------------------------------------------------------
  // 单文件

  Future<(int, int, int)> _downloadFile(
    NetStreamResponse up,
    Uint8List head,
    StreamIterator<List<int>> rest,
    String key,
  ) async {
    try {
      final identity = _identity(up);
      final declared = identity
          ? int.tryParse(up.headers['content-length'] ?? '')
          : null;
      if (declared != null && declared > limits.maxBytes) {
        throw SourceException(
          SourceErrorCode.limit,
          '视频超过 ${_gib(limits.maxBytes)}，不下载',
        );
      }
      await _clear();
      final etag = up.headers['etag'];
      final state = VideoFileState(
        length: declared,
        // 弱 ETag 不能用于 If-Range（RFC 9110 §13.1.5），视为没有校验值。
        etag: identity && etag != null && !etag.startsWith('W/') ? etag : null,
        lastModified: identity ? up.headers['last-modified'] : null,
      );
      var manifest = VideoManifest.file(
        sourceKey: key,
        label: _label,
        file: state,
      );
      await _writeManifest(manifest);
      manifest = manifest.copyWith(subtitles: await _downloadSubtitles(null));
      await _writeManifest(manifest);
      await _progress(0, 1, force: true);
      final written = await _appendBody(head, rest, append: false);
      if (declared != null && written != declared) {
        throw const SourceException(SourceErrorCode.network, '下载不完整');
      }
      await _progress(1, 1, force: true);
      return (1, 1, _bytes);
    } catch (e) {
      await rest.cancel();
      up.cancel();
      if (_isLimit(e)) await _clear();
      rethrow;
    }
  }

  Future<(int, int, int)> _resumeFile(
    NetStreamResponse up,
    VideoManifest manifest,
    int have,
  ) async {
    final it = StreamIterator(up.body);
    try {
      // 外挂字幕：已有的沿用，缺失的补下。
      final subs = await _downloadSubtitles(manifest.subtitles);
      await _writeManifest(manifest.copyWith(subtitles: subs));
      _bytes = have;
      await _progress(0, 1, force: true);
      final written = await _appendBody(Uint8List(0), it, append: true);
      if (have + written != manifest.file!.length) {
        throw const SourceException(SourceErrorCode.network, '下载不完整');
      }
      await _progress(1, 1, force: true);
      return (1, 1, _bytes);
    } catch (e) {
      await it.cancel();
      up.cancel();
      if (_isLimit(e)) await _clear();
      rethrow;
    }
  }

  /// 把响应体写入 `media.bin`（[append] 时接在后面），按实际字节计数执行合计上限。返回本次写入的字节数。
  Future<int> _appendBody(
    Uint8List head,
    StreamIterator<List<int>> rest, {
    required bool append,
  }) async {
    final file = DownloadStore.fileIn(dir, videoFileName);
    final IOSink sink;
    try {
      await dir.create(recursive: true);
      sink = file.openWrite(mode: append ? FileMode.append : FileMode.write);
    } on FileSystemException catch (e) {
      throw DownloadStorageException(e);
    }
    var written = 0;
    var sinceFlush = 0;
    var failed = false;
    Future<void> add(List<int> chunk) async {
      _bytes += chunk.length;
      written += chunk.length;
      if (_bytes > limits.maxBytes) {
        throw SourceException(
          SourceErrorCode.limit,
          '视频超过 ${_gib(limits.maxBytes)}，已中止',
        );
      }
      sink.add(chunk);
      sinceFlush += chunk.length;
      if (sinceFlush >= 4 * 1024 * 1024) {
        sinceFlush = 0;
        await sink.flush();
        await _progress(0, 1);
      }
    }

    try {
      if (head.isNotEmpty) await add(head);
      while (await rest.moveNext()) {
        await add(rest.current);
      }
      await sink.flush();
    } on FileSystemException catch (e) {
      failed = true;
      throw DownloadStorageException(e);
    } catch (_) {
      failed = true;
      rethrow;
    } finally {
      try {
        await sink.close();
      } on FileSystemException catch (e) {
        // 正常结束时关闭失败同样是写入失败；已有其他错误时以那个为准。
        if (!failed) throw DownloadStorageException(e);
      }
    }
    return written;
  }

  // ---------------------------------------------------------------------------
  // HLS

  Future<(int, int, int)> _downloadHls(
    String rootText,
    Uri rootUrl,
    VideoManifest? existing,
  ) async {
    final HlsDownloadSelection? selection;
    try {
      selection = selectHlsDownload(rootText, rootUrl);
    } on FormatException {
      throw const SourceException(SourceErrorCode.parse, '播放列表无效');
    }
    // (类型, 目录, 播放列表地址, 名称, 语言)
    final planned = <(VideoTrackType, String, Uri?, String?, String?)>[];
    if (selection == null) {
      planned.add((VideoTrackType.video, 'v', null, null, null));
    } else {
      final v = selection.variant.uri;
      if (v == null) {
        throw const SourceException(SourceErrorCode.parse, '变体地址无效');
      }
      planned.add((VideoTrackType.video, 'v', v, null, null));
      if (selection.audio case final a?) {
        planned.add((VideoTrackType.audio, 'a', a.uri, a.name, a.language));
      }
      for (final (i, s)
          in selection.subtitles.take(maxVideoSubtitleTracks).indexed) {
        planned.add((
          VideoTrackType.subtitles,
          videoTrackDir(VideoTrackType.subtitles, i),
          s.uri,
          s.name,
          s.language,
        ));
      }
    }

    final playlists = <HlsMediaPlaylist>[];
    for (final (_, _, uri, _, _) in planned) {
      final String text;
      final Uri base;
      if (uri == null) {
        (text, base) = (rootText, rootUrl);
      } else {
        final up = await _open(uri, lane: RateLimitLane.source);
        _checkStatus(up);
        final (head, rest) = await _peek(up, 1024);
        if (!looksLikeHlsPlaylist(head)) {
          await rest.cancel();
          up.cancel();
          throw const SourceException(SourceErrorCode.parse, '子播放列表无效');
        }
        text = await _collectText(head, rest, up);
        base = up.url;
      }
      try {
        playlists.add(parseHlsMediaPlaylist(text, base));
      } on HlsUnsupportedException catch (e) {
        throw SourceException(SourceErrorCode.unsupported, e.message);
      } on FormatException catch (e) {
        throw SourceException(SourceErrorCode.parse, e.message);
      }
    }
    final total = playlists.fold(0, (n, p) => n + p.items.length);
    if (total > limits.maxItems) {
      throw SourceException(
        SourceErrorCode.limit,
        '分片数超过 ${limits.maxItems}，不下载',
      );
    }

    // 来源标识（§4.5.1「续传」）：不用完整的分片地址（签名参数每次都变）。
    final key = _key([
      'hls',
      _streamIndex,
      _stream.quality,
      selection?.variant.bandwidth,
      selection?.variant.resolution,
      for (final (i, p) in playlists.indexed)
        [
          planned[i].$1.name,
          p.mediaSequence,
          p.segmentCount,
          for (final it in p.items)
            [
              it.kind.name,
              it.duration,
              strippedHlsUrl(it.uri),
              if (it.range case (final o, final n)?) [o, n],
            ],
        ],
    ]);

    final reuse =
        existing != null && existing.isHls && existing.sourceKey == key
        ? existing
        : null;
    if (reuse == null) await _clear();
    final tracks = <VideoTrack>[];
    for (final (i, p) in playlists.indexed) {
      final (type, dir, _, name, language) = planned[i];
      final old = reuse != null && i < reuse.tracks.length
          ? reuse.tracks[i]
          : null;
      final items = <VideoItem>[];
      for (final (j, it) in p.items.indexed) {
        String? file = old != null && j < old.items.length
            ? old.items[j].file
            : null;
        if (file != null &&
            await _length(DownloadStore.fileIn(this.dir, file)) <= 0) {
          file = null;
        }
        items.add(
          VideoItem(
            init: it.kind == HlsItemKind.init,
            duration: it.duration,
            discontinuity: it.discontinuity,
            file: file,
          ),
        );
      }
      tracks.add(
        VideoTrack(
          type: type,
          dir: dir,
          mediaSequence: p.mediaSequence,
          items: items,
          name: name,
          language: language,
        ),
      );
    }
    var manifest = VideoManifest.hls(
      sourceKey: key,
      label: _label,
      bandwidth: selection?.variant.bandwidth,
      resolution: selection?.variant.resolution,
      codecs: selection?.variant.codecs,
      tracks: tracks,
      subtitles: reuse?.subtitles ?? const [],
    );
    await _writeManifest(manifest);
    manifest = manifest.copyWith(
      subtitles: await _downloadSubtitles(reuse?.subtitles),
    );
    await _writeManifest(manifest);

    // 已写完的分片计入字节与进度。
    final files = [for (final t in tracks) List.of(t.items)];
    var completed = 0;
    for (final t in files) {
      for (final it in t) {
        if (it.file case final f?) {
          _bytes += await _length(DownloadStore.fileIn(dir, f));
          completed++;
        }
      }
    }
    if (_bytes > limits.maxBytes) {
      await _clear();
      throw SourceException(
        SourceErrorCode.limit,
        '视频超过 ${_gib(limits.maxBytes)}，已中止',
      );
    }
    await _progress(completed, total, force: true);

    final pending = <(int, int)>[
      for (final (t, items) in files.indexed)
        for (final (j, it) in items.indexed)
          if (it.file == null) (t, j),
    ];
    var next = 0;
    var sinceWrite = 0;
    Object? failure;
    StackTrace? failureStack;
    var writing = Future<void>.value();
    Future<void> flushManifest() {
      sinceWrite = 0;
      final snapshot = manifest.copyWith(
        tracks: [
          for (final (t, track) in tracks.indexed)
            track.withItems(List.of(files[t])),
        ],
      );
      return writing = writing.then((_) => _writeManifest(snapshot));
    }

    final keys = <Uri, Future<Uint8List>>{};
    Future<void> worker() async {
      while (failure == null && !abort.isCancelled && next < pending.length) {
        final (t, j) = pending[next++];
        final it = playlists[t].items[j];
        try {
          final name = await _fetchItem(
            it,
            subtitle: tracks[t].type == VideoTrackType.subtitles,
            dir: tracks[t].dir,
            index: j,
            keys: keys,
          );
          files[t][j] = files[t][j].withFile(name);
          completed++;
          await _progress(completed, total);
          if (++sinceWrite >= limits.manifestWriteInterval) {
            await flushManifest();
          }
        } catch (e, st) {
          if (failure == null) {
            failure = e;
            failureStack = st;
          }
          // 其余的并发请求随之中止。
          _localAbort.cancel();
        }
      }
    }

    try {
      await Future.wait([
        for (var i = 0; i < max(1, limits.concurrency); i++) worker(),
      ]);
    } finally {
      // 失败、取消与结束时都记下已写完的分片，续传时按来源标识跳过。
      await flushManifest();
      await writing;
    }
    if (failure case final e?) {
      if (_isLimit(e)) await _clear();
      Error.throwWithStackTrace(e, failureStack!);
    }
    if (abort.isCancelled) {
      throw const NetworkException(NetworkErrorKind.cancelled);
    }
    await _progress(completed, total, force: true);
    return (completed, total, _bytes);
  }

  /// 本任务内部的中止（一个分片失败时停掉其余的），也随 [abort] 取消。
  late final NetCancellation _localAbort = () {
    final c = NetCancellation();
    abort.whenCancelled.then((_) => c.cancel());
    return c;
  }();

  /// 下载一个分片，返回写完后的文件名。
  Future<String> _fetchItem(
    HlsItem it, {
    required bool subtitle,
    required String dir,
    required int index,
    required Map<Uri, Future<Uint8List>> keys,
  }) async {
    final aes = it.aes;
    final range = it.range;
    final up = await _open(
      it.uri,
      lane: RateLimitLane.media,
      cancellation: _localAbort,
      extra: {
        if (range case (final o, final n)? when aes == null)
          'range': 'bytes=$o-${o + n - 1}',
      },
    );
    if (range != null && aes == null) {
      final cr = _contentRange(up.headers['content-range']);
      if (up.status != HttpStatus.partialContent || cr?.$1 != range.$1) {
        up.cancel();
        throw const SourceException(SourceErrorCode.unsupported, '上游不支持字节区间');
      }
    } else {
      _checkStatus(up);
    }
    if (!_identity(up) && up.status != HttpStatus.ok) {
      up.cancel();
      throw const SourceException(SourceErrorCode.parse, '不支持的内容编码');
    }

    if (aes != null) {
      final keyUri = aes.keyUri;
      if (keyUri == null) {
        up.cancel();
        throw const SourceException(SourceErrorCode.unsupported, '密钥地址无效');
      }
      final Uint8List cipherText;
      final Uint8List key;
      try {
        key = await (keys[keyUri] ??= _fetchKey(keyUri)..ignore());
        final (head, rest) = await _peek(up, 1024);
        cipherText =
            (await _collect(head, rest, up, limits.maxEncryptedSegmentBytes)) ??
            (throw const SourceException(
              SourceErrorCode.limit,
              '加密分片超过 64 MB',
            ));
      } catch (_) {
        keys.remove(keyUri);
        up.cancel();
        rethrow;
      }
      final Uint8List plain;
      try {
        plain = decryptHlsAes128(cipherText, key, aes.iv);
      } on Object {
        throw const SourceException(SourceErrorCode.parse, '分片解密失败');
      }
      final ext = _extensionOf(
        Uint8List.sublistView(plain, 0, min(plain.length, 64 * 1024)),
        subtitle: subtitle,
      );
      _bytes += plain.length;
      if (_bytes > limits.maxBytes) {
        throw SourceException(
          SourceErrorCode.limit,
          '视频超过 ${_gib(limits.maxBytes)}，已中止',
        );
      }
      final name = videoItemFileName(dir, index, ext);
      try {
        await DownloadStore.writeBytes(
          Directory('${this.dir.path}${Platform.pathSeparator}$dir'),
          name.substring(dir.length + 1),
          plain,
        );
      } on FileSystemException catch (e) {
        throw DownloadStorageException(e);
      }
      return name;
    }

    final (head, rest) = await _peek(up, 64 * 1024);
    final String ext;
    try {
      ext = _extensionOf(head, subtitle: subtitle);
    } catch (_) {
      await rest.cancel();
      up.cancel();
      rethrow;
    }
    final name = videoItemFileName(dir, index, ext);
    final sub = Directory('${this.dir.path}${Platform.pathSeparator}$dir');
    final target = DownloadStore.fileIn(sub, name.substring(dir.length + 1));
    final part = File('${target.path}$partSuffix');
    IOSink? sink;
    var written = 0;
    try {
      await sub.create(recursive: true);
      sink = part.openWrite();
      Future<void> add(List<int> chunk) async {
        written += chunk.length;
        _bytes += chunk.length;
        if (range != null && written > range.$2) {
          throw const SourceException(SourceErrorCode.parse, '分片长度与字节区间不符');
        }
        if (_bytes > limits.maxBytes) {
          throw SourceException(
            SourceErrorCode.limit,
            '视频超过 ${_gib(limits.maxBytes)}，已中止',
          );
        }
        sink!.add(chunk);
        if (written % (4 * 1024 * 1024) < chunk.length) await sink.flush();
      }

      await add(head);
      while (await rest.moveNext()) {
        await add(rest.current);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (range != null && written != range.$2) {
        throw const SourceException(SourceErrorCode.network, '分片不完整');
      }
      await part.rename(target.path);
      return name;
    } on FileSystemException catch (e) {
      throw DownloadStorageException(e);
    } finally {
      await rest.cancel();
      up.cancel();
      if (sink != null) {
        try {
          await sink.close();
        } on Object {
          // 已在出错路径上。
        }
      }
      if (await part.exists()) {
        try {
          await part.delete();
        } on FileSystemException {
          // 启动时会清理残留的 *.part。
        }
      }
    }
  }

  /// 取 AES-128 密钥（媒体配额，必须为 16 字节）；不保存。
  Future<Uint8List> _fetchKey(Uri uri) async {
    final up = await _open(
      uri,
      lane: RateLimitLane.media,
      cancellation: _localAbort,
    );
    if (up.status != HttpStatus.ok) {
      up.cancel();
      throw SourceException(
        SourceErrorCode.http,
        'HTTP ${up.status}',
        up.status,
      );
    }
    final (head, rest) = await _peek(up, 64);
    final key = await _collect(head, rest, up, 4096);
    if (key == null || key.length != 16) {
      throw const SourceException(SourceErrorCode.parse, '密钥无效');
    }
    return key;
  }

  String _extensionOf(Uint8List head, {required bool subtitle}) {
    if (subtitle) {
      if (!looksLikeWebVtt(head)) {
        throw const SourceException(SourceErrorCode.parse, '字幕分片不是 WebVTT');
      }
      return 'vtt';
    }
    final container = sniffMediaContainer(head);
    if (container == null) {
      throw const SourceException(SourceErrorCode.parse, '分片内容无法识别');
    }
    return container.extension;
  }

  // ---------------------------------------------------------------------------
  // 外挂字幕

  /// 下载 `content.subtitles`（按原样保存，离线时由 Dart 侧解析）。[existing] 中文件仍在的沿用。
  /// 格式不可用（伪装成字幕的 HTML 等）或上游 4xx 的条目跳过——在线播放时它们同样只是“加载失败”；
  /// 其他网络错误让该剧集失败（可重试）。
  Future<List<VideoSubtitleEntry>> _downloadSubtitles(
    List<VideoSubtitleEntry>? existing,
  ) async {
    final out = <VideoSubtitleEntry>[];
    final refs = content.subtitles.take(maxVideoSubtitles).toList();
    for (final (i, ref) in refs.indexed) {
      final prefix = 'sub-${(i + 1).toString().padLeft(2, '0')}.';
      final kept = existing
          ?.where((s) => s.file.startsWith(prefix))
          .firstOrNull;
      if (kept != null &&
          kept.lang == ref.lang &&
          kept.format == ref.format &&
          kept.charset == ref.charset &&
          await _length(DownloadStore.fileIn(dir, kept.file)) > 0) {
        out.add(kept);
        continue;
      }
      try {
        final declared = declaredSubtitleFormat(ref.format);
        final url = baseUrl.resolve(ref.url.trim()).toString();
        final (bytes, contentType) = await fetchSubtitleBytes(
          client,
          url,
          cancellation: _localAbort,
        );
        final doc = await parseSubtitleBytes(
          bytes,
          charset: ref.charset,
          contentType: contentType,
          declared: declared,
        );
        final name = videoSubtitleFileName(i, doc.format.name);
        try {
          await DownloadStore.writeBytes(dir, name, bytes);
        } on FileSystemException catch (e) {
          throw DownloadStorageException(e);
        }
        _bytes += bytes.length;
        out.add(
          VideoSubtitleEntry(
            file: name,
            lang: ref.lang,
            format: ref.format,
            charset: ref.charset,
            contentType: _safeContentType(contentType),
          ),
        );
      } on SubtitleFormatException {
        continue;
      } on FormatException {
        continue;
      } on NetworkException catch (e) {
        if (e.kind == NetworkErrorKind.http &&
            (e.status ?? 0) >= 400 &&
            (e.status ?? 0) < 500) {
          continue;
        }
        rethrow;
      }
    }
    return out;
  }

  static String? _safeContentType(String? v) =>
      v != null && v.length <= 256 && RegExp(r'^[\x20-\x7e]*$').hasMatch(v)
      ? v
      : null;

  // ---------------------------------------------------------------------------
  // 公共部分

  Future<NetStreamResponse> _open(
    Uri url, {
    required RateLimitLane lane,
    NetCancellation? cancellation,
    Map<String, String> extra = const {},
  }) => client.openStream(
    lane: lane,
    NetRequest(
      url.toString(),
      headers: {
        ..._headers,
        // 按原样字节传输（区间续传、分片长度校验）；不允许被 StreamRef.headers 覆盖。
        'accept-encoding': 'identity',
        ...extra,
      },
      cancellation: cancellation ?? abort,
    ),
  );

  static void _checkStatus(NetStreamResponse up) {
    if (up.status >= 200 && up.status < 300) {
      if (!_identity(up) && up.status != HttpStatus.ok) {
        up.cancel();
        throw const SourceException(SourceErrorCode.parse, '不支持的内容编码');
      }
      final enc = (up.headers['content-encoding'] ?? 'identity')
          .trim()
          .toLowerCase();
      if (enc != 'identity' && enc != 'gzip') {
        up.cancel();
        throw const SourceException(SourceErrorCode.parse, '不支持的内容编码');
      }
      return;
    }
    up.cancel();
    throw SourceException(SourceErrorCode.http, 'HTTP ${up.status}', up.status);
  }

  static bool _identity(NetStreamResponse up) =>
      (up.headers['content-encoding'] ?? 'identity').trim().toLowerCase() ==
      'identity';

  /// `bytes a-b/total` → (a, b, total)；总长度为 `*` 时 total 为 null。
  static (int, int, int?)? _contentRange(String? v) {
    final m = RegExp(r'^bytes (\d+)-(\d+)/(\d+|\*)$')
        .firstMatch(v?.trim() ?? '');
    if (m == null) return null;
    return (int.parse(m[1]!), int.parse(m[2]!), int.tryParse(m[3]!));
  }

  Future<(Uint8List, StreamIterator<List<int>>)> _peek(
    NetStreamResponse up,
    int n,
  ) async {
    final it = StreamIterator(up.body);
    final head = BytesBuilder(copy: false);
    final rest = <List<int>>[];
    while (head.length < n && await it.moveNext()) {
      final chunk = it.current;
      final take = min(n - head.length, chunk.length);
      head.add(chunk.sublist(0, take));
      if (take < chunk.length) rest.add(chunk.sublist(take));
    }
    return (head.takeBytes(), _Prefixed(rest, it));
  }

  Future<Uint8List?> _collect(
    Uint8List head,
    StreamIterator<List<int>> rest,
    NetStreamResponse up,
    int limit,
  ) async {
    final out = BytesBuilder(copy: false)..add(head);
    try {
      while (await rest.moveNext()) {
        out.add(rest.current);
        if (out.length > limit) return null;
      }
      return out.takeBytes();
    } finally {
      await rest.cancel();
      up.cancel();
    }
  }

  Future<String> _collectText(
    Uint8List head,
    StreamIterator<List<int>> rest,
    NetStreamResponse up,
  ) async {
    final body = await _collect(head, rest, up, limits.maxPlaylistBytes);
    if (body == null) {
      throw const SourceException(SourceErrorCode.limit, '播放列表超过 4 MB');
    }
    return utf8.decode(body, allowMalformed: true);
  }

  DateTime? _lastProgress;

  Future<void> _progress(int completed, int total, {bool force = false}) async {
    final now = DateTime.now();
    if (!force &&
        _lastProgress != null &&
        now.difference(_lastProgress!) < limits.progressInterval) {
      return;
    }
    _lastProgress = now;
    await onProgress(completed, total, _bytes);
  }

  Future<VideoManifest?> _readManifest() async {
    final f = DownloadStore.fileIn(dir, videoManifestFileName);
    if (!await f.exists()) return null;
    return VideoManifest.decode(await f.readAsString());
  }

  Future<void> _writeManifest(VideoManifest m) async {
    try {
      await DownloadStore.writeText(dir, videoManifestFileName, m.encode());
    } on FileSystemException catch (e) {
      throw DownloadStorageException(e);
    }
  }

  Future<void> _clear() => DownloadStore.clear(dir);

  static Future<int> _length(File f) async {
    try {
      return await f.length();
    } on FileSystemException {
      return -1;
    }
  }

  static bool _isLimit(Object e) =>
      e is SourceException && e.code == SourceErrorCode.limit;

  static String _key(List<Object?> parts) => sha256Hex(jsonEncode(parts));

  static String _gib(int bytes) => bytes >= 1024 * 1024 * 1024
      ? '${bytes ~/ (1024 * 1024 * 1024)} GiB'
      : '${bytes ~/ (1024 * 1024)} MiB';
}

/// 先交出已读出的 [_pending]，再继续读 [_it]。
final class _Prefixed implements StreamIterator<List<int>> {
  _Prefixed(this._pending, this._it);

  final List<List<int>> _pending;
  final StreamIterator<List<int>> _it;
  List<int>? _current;

  @override
  List<int> get current => _current ?? (throw StateError('no current'));

  @override
  Future<bool> moveNext() async {
    if (_pending.isNotEmpty) {
      _current = _pending.removeAt(0);
      return true;
    }
    final ok = await _it.moveNext();
    _current = ok ? _it.current : null;
    return ok;
  }

  @override
  Future<void> cancel() => _it.cancel();
}
