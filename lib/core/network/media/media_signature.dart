/// 按文件头识别常见的音视频容器（architecture §6.4）。
///
/// 本地媒体代理只把能在这里识别的内容当作媒体交给播放器；文本（任何编码）、HTML、
/// HLS 以外的播放列表 / 清单（m3u、pls、DASH MPD、ffconcat、EDL……）都识别不出来，会被拒绝。
/// 每种签名都要求文本中不会出现的字节（控制字节或固定的二进制字段），
/// 因此一段可打印文本不会被误认为媒体。
///
/// 另外要求开头一段中至少有一个控制字节（0x00–0x08、0x0E–0x1F），作为对文本的第二道检查；
/// 真实的媒体文件开头几乎总有（盒大小、PID、标志位中的 0x00）。
bool looksLikeMediaContainer(List<int> b) => sniffMediaContainer(b) != null;

/// 识别出的容器；与 [looksLikeMediaContainer] 的判定完全一致（不是媒体时为 null）。
MediaContainer? sniffMediaContainer(List<int> b) =>
    b.length >= 4 && !_hasUtf16Bom(b) && _hasControlByte(b)
    ? _signature(b)
    : null;

/// 可识别的容器。[extension] 为代理给 HLS 分片取的扩展名（architecture §6.4.3）：
/// 与 FFmpeg（7.1.1 起）HLS 解复用器按探测出的格式要求的扩展名一致。
enum MediaContainer {
  mpegTs('ts'),
  isoBmff('mp4'),
  matroska('mkv'),
  flv('flv'),
  ogg('ogg'),
  adts('aac'),
  mpegAudio('mp3'),
  ac3('ac3'),
  eac3('eac3'),
  flac('flac'),
  avi('avi'),
  wav('wav');

  const MediaContainer(this.extension);

  final String extension;
}

/// UTF-16 / UTF-32 的字节序标记（`FF FE` 与 MPEG 音频的帧同步字形式相同，必须先排除）。
bool _hasUtf16Bom(List<int> b) =>
    (b[0] == 0xFF && b[1] == 0xFE) ||
    (b[0] == 0xFE && b[1] == 0xFF) ||
    (b[0] == 0 && b[1] == 0 && b[2] == 0xFE && b[3] == 0xFF);

bool _hasControlByte(List<int> b) =>
    b.any((c) => c <= 0x08 || (c >= 0x0E && c <= 0x1F));

MediaContainer? _signature(List<int> b) {
  // MPEG-TS：188 字节的包，以同步字节 0x47 开头（有第二个包时一并检查）。
  if (b.length >= 188 && b[0] == 0x47 && (b.length < 189 || b[188] == 0x47)) {
    return MediaContainer.mpegTs;
  }
  // ISO-BMFF（MP4 / fMP4 / CMAF / MOV）：32 位盒大小 + 已知盒类型；盒大小的高字节为 0。
  if (b.length >= 8 && b[0] == 0 && _isoBoxes.contains(_ascii(b, 4, 8))) {
    return MediaContainer.isoBmff;
  }
  // Matroska / WebM（EBML 头）。
  if (_has(b, 0, const [0x1A, 0x45, 0xDF, 0xA3])) {
    return MediaContainer.matroska;
  }
  // FLV：'FLV' + 版本 1。
  if (_has(b, 0, const [0x46, 0x4C, 0x56, 0x01])) return MediaContainer.flv;
  // Ogg：'OggS' + 版本 0。
  if (b.length >= 5 && _has(b, 0, const [0x4F, 0x67, 0x67, 0x53, 0x00])) {
    return MediaContainer.ogg;
  }
  // ID3v2 标签（HLS 打包音频、MP3）：'ID3' + 主版本 2..4 + 次版本 0xFF 以下。
  if (b.length >= 10 &&
      _has(b, 0, const [0x49, 0x44, 0x33]) &&
      b[3] >= 2 &&
      b[3] <= 4 &&
      b[4] != 0xFF) {
    return _afterId3(b);
  }
  return _audioFrame(b, 0) ?? _otherSignature(b);
}

/// 音频帧同步字（[at] 处）：ADTS AAC / MPEG 音频 / AC-3 / E-AC-3。
MediaContainer? _audioFrame(List<int> b, int at) {
  if (b.length < at + 2) return null;
  // ADTS AAC / MPEG 音频帧：11 位同步字；layer 为 0 的是 ADTS。
  if (b[at] == 0xFF && (b[at + 1] & 0xE0) == 0xE0) {
    return (b[at + 1] & 0x06) == 0
        ? MediaContainer.adts
        : MediaContainer.mpegAudio;
  }
  // AC-3 / E-AC-3 同步字；bsid（第 6 字节高 5 位）大于 10 为 E-AC-3。
  if (b[at] == 0x0B && b[at + 1] == 0x77) {
    return b.length > at + 5 && (b[at + 5] >> 3) > 10
        ? MediaContainer.eac3
        : MediaContainer.ac3;
  }
  return null;
}

/// ID3v2 标签之后的音频帧决定格式（HLS 打包音频以 ID3 时间戳开头）；
/// 标签之后不在已读的范围内或无法识别时按最常见的 ADTS AAC。
MediaContainer _afterId3(List<int> b) {
  final size =
      (b[6] & 0x7F) << 21 |
      (b[7] & 0x7F) << 14 |
      (b[8] & 0x7F) << 7 |
      b[9] & 0x7F;
  final footer = (b[5] & 0x10) != 0 ? 10 : 0;
  return _audioFrame(b, 10 + size + footer) ?? MediaContainer.adts;
}

MediaContainer? _otherSignature(List<int> b) {
  // FLAC。
  if (_has(b, 0, const [0x66, 0x4C, 0x61, 0x43]) &&
      b.length >= 5 &&
      (b[4] & 0x7F) == 0) {
    return MediaContainer.flac;
  }
  // RIFF（AVI / WAV）：'RIFF' + 小端长度 + 'AVI ' / 'WAVE'。
  if (b.length >= 12 && _has(b, 0, const [0x52, 0x49, 0x46, 0x46])) {
    return switch (_ascii(b, 8, 12)) {
      'AVI ' => MediaContainer.avi,
      'WAVE' => MediaContainer.wav,
      _ => null,
    };
  }
  return null;
}

const _isoBoxes = {
  'ftyp', 'styp', 'moov', 'moof', 'mdat', 'sidx', 'emsg', 'prft', //
  'free', 'skip', 'wide', 'pdin', 'uuid',
};

bool _has(List<int> b, int at, List<int> sig) {
  if (b.length < at + sig.length) return false;
  for (var i = 0; i < sig.length; i++) {
    if (b[at + i] != sig[i]) return false;
  }
  return true;
}

String _ascii(List<int> b, int from, int to) =>
    String.fromCharCodes(b.sublist(from, to));
