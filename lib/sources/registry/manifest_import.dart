import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../model/common.dart';
import '../model/manifest.dart';

/// 导入失败的原因。
enum SourceImportError {
  /// 不是合法的 JSON 对象。
  invalidJson,

  /// 缺字段、类型错误或未通过 [SourceManifest.validate]。
  invalidManifest,

  /// `apiVersion` 不被当前客户端支持。
  unsupportedApiVersion,

  /// 已安装的版本更高。
  downgrade,

  /// 已安装完全相同的清单。
  alreadyInstalled,
}

class SourceImportException implements Exception {
  SourceImportException(this.error, List<String> messages)
    : messages = List.unmodifiable(messages);

  SourceImportException.single(SourceImportError error, String message)
    : this(error, [message]);

  final SourceImportError error;

  /// 面向用户的说明（中文），至少一条。
  final List<String> messages;

  String get message => messages.join('\n');

  @override
  String toString() => 'SourceImportException(${error.name}: $message)';
}

/// 解析成功的清单原文。
final class ParsedManifest {
  const ParsedManifest({
    required this.manifest,
    required this.manifestJson,
    required this.sha256,
    required this.unknownFields,
  });

  final SourceManifest manifest;

  /// 原文（不做任何规范化）。
  final String manifestJson;

  /// 清单原始字节的 sha256，小写十六进制（与仓库 index.json 中的 sha256 同口径）。
  final String sha256;

  /// 顶层未知字段（docs/source-spec.md §1：忽略但给出警告）。
  final List<String> unknownFields;
}

/// docs/source-spec.md §1 定义的顶层字段。
const knownManifestFields = {
  'apiVersion',
  'id',
  'name',
  'type',
  'version',
  'author',
  'description',
  'lang',
  'nsfw',
  'icon',
  'baseUrl',
  'allowedHosts',
  'headers',
  'rateLimit',
  'timeoutMs',
  'settings',
  'engine',
  'rules',
  'script',
};

/// 把文件字节解码为文本（UTF-8，去掉 BOM）。
String decodeManifestBytes(List<int> bytes) {
  try {
    final text = utf8.decode(bytes);
    return text.startsWith('﻿') ? text.substring(1) : text;
  } on FormatException {
    throw SourceImportException.single(
      SourceImportError.invalidJson,
      '文件不是 UTF-8 编码的文本',
    );
  }
}

/// 解析并校验清单原文，失败时抛出 [SourceImportException]。
///
/// [rawBytes] 为文件原始字节（若有），sha256 按它计算；否则按 [text] 的 UTF-8 编码计算。
ParsedManifest parseManifest(String text, {List<int>? rawBytes}) {
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException catch (e) {
    throw SourceImportException.single(
      SourceImportError.invalidJson,
      'JSON 格式错误：${e.message}',
    );
  }
  if (decoded is! Map<String, dynamic>) {
    throw SourceImportException.single(
      SourceImportError.invalidJson,
      '清单必须是一个 JSON 对象',
    );
  }

  // 先看 apiVersion：更高版本的清单结构可能完全不同，不应再报字段错误。
  final api = decoded['apiVersion'];
  if (api is! int) {
    throw SourceImportException.single(
      SourceImportError.invalidManifest,
      api == null ? '缺少 apiVersion 字段' : 'apiVersion 必须是整数',
    );
  }
  if (!supportedApiVersions.contains(api)) {
    final supported = (supportedApiVersions.toList()..sort()).join('、');
    final newest = supportedApiVersions.reduce((a, b) => a > b ? a : b);
    throw SourceImportException.single(
      SourceImportError.unsupportedApiVersion,
      api > newest
          ? '该源需要更新版本的客户端（源的 apiVersion 为 $api，当前客户端支持 $supported）'
          : '该源的 apiVersion $api 已不再受支持（当前客户端支持 $supported），请联系源作者更新',
    );
  }

  final errors = <String>[
    for (final (key, check, hint) in _requiredFields)
      if (decoded[key] == null)
        '缺少必填字段 $key'
      else if (!check(decoded[key]))
        '字段 $key $hint',
  ];
  if (errors.isNotEmpty) {
    throw SourceImportException(SourceImportError.invalidManifest, errors);
  }

  final SourceManifest manifest;
  try {
    manifest = SourceManifest.fromJson(decoded);
  } catch (e) {
    throw SourceImportException.single(
      SourceImportError.invalidManifest,
      '清单字段类型错误：$e',
    );
  }
  final validation = manifest.validate();
  if (validation.isNotEmpty) {
    throw SourceImportException(SourceImportError.invalidManifest, validation);
  }

  return ParsedManifest(
    manifest: manifest,
    manifestJson: text,
    sha256: sha256.convert(rawBytes ?? utf8.encode(text)).toString(),
    unknownFields: [
      for (final k in decoded.keys)
        if (!knownManifestFields.contains(k)) k,
    ],
  );
}

bool _isString(Object? v) => v is String;
bool Function(Object?) _isEnum(List<Enum> values) =>
    (v) => v is String && values.any((e) => e.name == v);

final _requiredFields = <(String, bool Function(Object?), String)>[
  ('id', _isString, '必须是字符串'),
  ('name', _isString, '必须是字符串'),
  (
    'type',
    _isEnum(MediaType.values),
    '必须是 ${MediaType.values.map((e) => e.name).join(' / ')} 之一',
  ),
  ('version', _isString, '必须是字符串'),
  ('baseUrl', _isString, '必须是字符串'),
  (
    'engine',
    _isEnum(SourceEngine.values),
    '必须是 ${SourceEngine.values.map((e) => e.name).join(' / ')} 之一',
  ),
];
