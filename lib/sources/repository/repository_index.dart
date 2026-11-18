import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../model/common.dart';
import '../model/manifest.dart';
import 'repository_exception.dart';
import 'repository_http_client.dart';

/// 客户端支持的索引 `repoVersion`（source-spec §7）。
const supportedRepoVersions = {1};

/// 索引中的一个源条目（source-spec §7）。
final class RepositoryEntry {
  const RepositoryEntry({
    required this.id,
    required this.name,
    required this.type,
    required this.version,
    required this.apiVersion,
    required this.url,
    required this.sha256,
    this.lang,
    this.nsfw = false,
  });

  final String id;
  final String name;
  final MediaType type;
  final String version;
  final int apiVersion;

  /// 清单的绝对地址（已按 index.json 地址解析并检查）。
  final Uri url;

  /// 清单原始字节的 sha256，小写十六进制。
  final String sha256;
  final String? lang;
  final bool nsfw;

  /// 客户端是否支持该条目的 `apiVersion`；不支持时只能浏览，不能安装。
  bool get apiSupported => supportedApiVersions.contains(apiVersion);
}

/// 解析后的仓库索引。
final class RepositoryIndex {
  const RepositoryIndex({
    required this.url,
    required this.repoVersion,
    required this.name,
    required this.entries,
    required this.rawJson,
    required this.sha256,
  });

  /// 规范化后的 index.json 地址。
  final Uri url;
  final int repoVersion;
  final String name;
  final List<RepositoryEntry> entries;

  /// 索引原文（UTF-8）。
  final String rawJson;

  /// 索引原始字节的 sha256。
  final String sha256;

  RepositoryEntry? entry(String id) {
    for (final e in entries) {
      if (e.id == id) return e;
    }
    return null;
  }
}

/// 规范化用户输入的仓库地址：去空白与片段、协议与主机小写、去默认端口；
/// 路径为空或以 `/` 结尾时补上 `index.json`。地址无效或不安全时抛出 [RepositoryException]。
Uri normalizeRepositoryUrl(String input, {bool allowLoopbackHttp = false}) {
  final Uri parsed;
  try {
    parsed = Uri.parse(input.trim());
  } on FormatException {
    throw RepositoryException(RepositoryErrorKind.invalidUrl, '仓库地址无效：$input');
  }
  if (!parsed.hasScheme || parsed.host.isEmpty) {
    throw RepositoryException(
      RepositoryErrorKind.invalidUrl,
      '仓库地址必须是完整的 https 地址：$input',
    );
  }
  checkRepositoryUri(parsed, allowLoopbackHttp: allowLoopbackHttp);
  var path = parsed.path;
  if (path.isEmpty || path.endsWith('/')) {
    path = '${path.isEmpty ? '/' : path}index.json';
  }
  final scheme = parsed.scheme.toLowerCase();
  final defaultPort = scheme == 'https' ? 443 : 80;
  return Uri(
    scheme: scheme,
    host: parsed.host.toLowerCase(),
    port: parsed.hasPort && parsed.port != defaultPort ? parsed.port : null,
    path: path,
    query: parsed.hasQuery ? parsed.query : null,
  );
}

final _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

/// 解析并校验索引原始字节（source-spec §7）。任何一处不合规则整个索引无效。
RepositoryIndex parseRepositoryIndex(
  List<int> bytes,
  Uri indexUrl, {
  bool allowLoopbackHttp = false,
}) {
  Never invalid(String message) =>
      throw RepositoryException(RepositoryErrorKind.invalidIndex, message);

  final String text;
  try {
    text = utf8.decode(bytes);
  } on FormatException {
    invalid('索引不是 UTF-8 编码的文本');
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(text.startsWith('﻿') ? text.substring(1) : text);
  } on FormatException catch (e) {
    invalid('索引 JSON 格式错误：${e.message}');
  }
  if (decoded is! Map<String, dynamic>) invalid('索引必须是一个 JSON 对象');

  final repoVersion = decoded['repoVersion'];
  if (repoVersion is! int) invalid('索引缺少整数字段 repoVersion');
  if (!supportedRepoVersions.contains(repoVersion)) {
    throw RepositoryException(
      RepositoryErrorKind.unsupportedRepoVersion,
      '该仓库需要更新版本的客户端（repoVersion 为 $repoVersion）',
    );
  }
  final name = decoded['name'];
  if (name is! String || name.trim().isEmpty) invalid('索引缺少字段 name');
  final sources = decoded['sources'];
  if (sources is! List) invalid('索引缺少数组字段 sources');

  final entries = <RepositoryEntry>[];
  final ids = <String>{};
  for (var i = 0; i < sources.length; i++) {
    final raw = sources[i];
    final where = '第 ${i + 1} 个条目';
    if (raw is! Map<String, dynamic>) invalid('$where 必须是 JSON 对象');
    String str(String key) {
      final v = raw[key];
      if (v is! String || v.isEmpty) invalid('$where 缺少字符串字段 $key');
      return v;
    }

    final id = str('id');
    if (!ids.add(id)) invalid('索引中 id 重复：$id');
    final type =
        MediaType.values.asNameMap()[str('type')] ??
        invalid('$where 的 type 无效：${raw['type']}');
    final apiVersion = raw['apiVersion'];
    if (apiVersion is! int) invalid('$where 缺少整数字段 apiVersion');
    final hash = str('sha256');
    if (!_sha256Pattern.hasMatch(hash)) {
      invalid('$where 的 sha256 必须是 64 位小写十六进制');
    }
    final Uri url;
    try {
      url = indexUrl.resolve(str('url'));
    } on FormatException {
      invalid('$where 的 url 无效');
    }
    if (!isAllowedRepositoryUri(url, allowLoopbackHttp: allowLoopbackHttp)) {
      invalid('$where 的 url 必须是 https：$url');
    }
    final lang = raw['lang'];
    if (lang != null && lang is! String) invalid('$where 的 lang 必须是字符串');
    final nsfw = raw['nsfw'];
    if (nsfw != null && nsfw is! bool) invalid('$where 的 nsfw 必须是布尔值');
    entries.add(
      RepositoryEntry(
        id: id,
        name: str('name'),
        type: type,
        version: str('version'),
        apiVersion: apiVersion,
        url: url,
        sha256: hash,
        lang: lang as String?,
        nsfw: nsfw as bool? ?? false,
      ),
    );
  }
  return RepositoryIndex(
    url: indexUrl,
    repoVersion: repoVersion,
    name: name.trim(),
    entries: List.unmodifiable(entries),
    rawJson: text,
    sha256: sha256.convert(bytes).toString(),
  );
}
