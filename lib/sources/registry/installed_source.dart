import 'dart:convert';

import '../../core/storage/app_database.dart';
import '../model/common.dart';
import '../model/manifest.dart';

/// 源的安装来源。
final class SourceOrigin {
  /// 本地导入；[label] 可选，例如文件名。
  const SourceOrigin.local([this.label]) : kind = SourceOriginKind.local;

  /// 从规则仓库安装（M6），[label] 为清单 URL。
  const SourceOrigin.repository(String url)
    : kind = SourceOriginKind.repository,
      label = url;

  const SourceOrigin._(this.kind, this.label);

  final SourceOriginKind kind;
  final String? label;

  @override
  bool operator ==(Object other) =>
      other is SourceOrigin && other.kind == kind && other.label == label;

  @override
  int get hashCode => Object.hash(kind, label);

  @override
  String toString() => 'SourceOrigin(${kind.name}, $label)';
}

/// 一个已安装的源（只是清单与管理状态，不是可运行的 [Source] 实例）。
final class InstalledSource {
  const InstalledSource({
    required this.id,
    required this.name,
    required this.type,
    required this.version,
    required this.apiVersion,
    required this.enabled,
    required this.sortOrder,
    required this.installedAt,
    required this.updatedAt,
    required this.origin,
    required this.manifestSha256,
    required this.manifestJson,
    required this.manifest,
    this.loadError,
  });

  /// 从数据库行还原。清单无法解析（例如客户端被降级）时 [manifest] 为 null，
  /// 原因写入 [loadError]，其余字段仍可用于列表展示与删除。
  factory InstalledSource.fromRow(InstalledSourceRow row) {
    SourceManifest? manifest;
    String? error;
    try {
      manifest = SourceManifest.fromJson(
        jsonDecode(row.manifestJson) as Map<String, dynamic>,
      );
      final errors = manifest.validate();
      if (errors.isNotEmpty) {
        manifest = null;
        error = errors.join('\n');
      }
    } catch (e) {
      error = '清单无法解析：$e';
    }
    return InstalledSource(
      id: row.id,
      name: row.name,
      type: MediaType.values.asNameMap()[row.type] ?? MediaType.comic,
      version: row.version,
      apiVersion: row.apiVersion,
      enabled: row.enabled,
      sortOrder: row.sortOrder,
      installedAt: row.installedAt,
      updatedAt: row.updatedAt,
      origin: SourceOrigin._(row.originKind, row.originUrl),
      manifestSha256: row.manifestSha256,
      manifestJson: row.manifestJson,
      manifest: manifest,
      loadError: error,
    );
  }

  final String id;
  final String name;
  final MediaType type;
  final String version;
  final int apiVersion;
  final bool enabled;
  final int sortOrder;
  final DateTime installedAt;
  final DateTime updatedAt;
  final SourceOrigin origin;
  final String manifestSha256;
  final String manifestJson;
  final SourceManifest? manifest;
  final String? loadError;

  /// 清单可用且已启用。
  bool get isUsable => enabled && manifest != null;

  @override
  String toString() => 'InstalledSource($id $version, enabled: $enabled)';
}

/// 源会访问的主机：`baseUrl` 的主机 + `allowedHosts`（去重，保持顺序）。
List<String> manifestHosts(SourceManifest manifest) {
  final base = Uri.tryParse(manifest.baseUrl)?.host;
  return {
    if (base != null && base.isNotEmpty) base.toLowerCase(),
    for (final h in manifest.allowedHosts) h.toLowerCase(),
  }.toList();
}
