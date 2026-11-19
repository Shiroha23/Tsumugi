import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../sources/model/common.dart';

/// 下载目录的布局（docs/architecture.md §4.5）。
///
/// 路径**只由哈希与序号**生成，不使用源返回的任何字符串（标题、id、URL）作为文件名：
/// `<root>/<h(sourceId)>/<h(itemId)>/<h(unitId)>/`，其中 `h` 为 sha256 的前 32 位十六进制（128 位，[pathHash]）：
/// 完整的 64 位会让三段目录加上 Windows 的应用支持目录超过 `MAX_PATH`（260）。
/// 漫画页为 `0001.<ext>` 起编号，小说为 [chapterFileName] 与 `img-0001.<ext>`；
/// 每个 unit 目录另有 [unitFileName] 与完成标记 [doneFileName]。

/// 小写十六进制的 sha256。
String sha256Hex(String value) => sha256.convert(utf8.encode(value)).toString();

/// 可用于下载文件的扩展名（按文件头识别，见 `sniffImageExtension`）。
const downloadImageExtensions = {'png', 'jpg', 'gif', 'webp'};

const unitFileName = 'unit.json';
const chapterFileName = 'chapter.json';
const doneFileName = '.done';

/// 写入中的临时文件后缀：校验通过后改名为正式文件名。
const partSuffix = '.part';

/// 漫画第 [index] 页（从 0 开始）的文件名：`0001.png`。
String comicPageFileName(int index, String extension) =>
    '${_seq(index)}.$extension';

/// 小说第 [index] 张正文图片（从 0 开始）的文件名：`img-0001.png`。
String novelImageFileName(int index, String extension) =>
    'img-${_seq(index)}.$extension';

String _seq(int index) {
  if (index < 0) throw RangeError.value(index, 'index');
  return (index + 1).toString().padLeft(4, '0');
}

final _comicPage = RegExp(r'^\d{4,}\.(png|jpg|gif|webp)$');
final _novelImage = RegExp(r'^img-\d{4,}\.(png|jpg|gif|webp)$');

/// `unit.json` 中的文件名是否是本客户端会生成的形式（防止损坏或被改写的记录指向目录外）。
bool isValidDownloadFileName(String name) =>
    _comicPage.hasMatch(name) || _novelImage.hasMatch(name);

/// 目录名：sha256 的前 32 位十六进制（128 位）。
String pathHash(String value) => sha256Hex(value).substring(0, 32);

/// 由 sourceId / itemId / unitId 得到相对下载根目录的路径段。
List<String> unitPathSegments(String sourceId, String itemId, String unitId) =>
    [pathHash(sourceId), pathHash(itemId), pathHash(unitId)];

List<String> itemPathSegments(String sourceId, String itemId) => [
  pathHash(sourceId),
  pathHash(itemId),
];

/// 一张图片的来源标识：地址 + 请求头的规范化 JSON（键排序）的 sha256。
///
/// 续传时比较新旧两次 `content()` 的标识列表，完全一致才沿用已下载的文件（§4.5）。
String imageSourceKey(String url, Headers? headers) {
  final sorted = headers == null
      ? null
      : (headers.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
  return sha256Hex(
    jsonEncode([
      url,
      if (sorted != null)
        [
          for (final e in sorted) [e.key, e.value],
        ],
    ]),
  );
}
