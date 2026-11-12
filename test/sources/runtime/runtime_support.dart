import 'dart:convert';
import 'dart:io';

import 'package:tsumugi/core/network/dio_source_http_client.dart';
import 'package:tsumugi/core/storage/source_storage.dart';
import 'package:tsumugi/sources/declarative/declarative_source_factory.dart';
import 'package:tsumugi/sources/model/common.dart';
import 'package:tsumugi/sources/model/content.dart';
import 'package:tsumugi/sources/model/manifest.dart';
import 'package:tsumugi/sources/network_error_mapping.dart';
import 'package:tsumugi/sources/registry/source_factory.dart';
import 'package:tsumugi/sources/runtime/source_runtime.dart';
import 'package:tsumugi/sources/script/script_source_factory.dart';
import 'package:tsumugi/sources/source.dart';

import '../../core/network/mock_support.dart';

/// 指向 tool/mock_server 的虚构漫画源清单（声明式 / 脚本）。
String mockSourceJson(String name, [Map<String, Object?> changes = const {}]) =>
    jsonEncode({
      ...jsonDecode(
        File('test/fixtures/sources/mock_comic_$name.json').readAsStringSync(),
      ) as Map<String, dynamic>,
      ...changes,
    });

/// 声明式与脚本引擎的真实工厂，HTTP 连接都接到本地 [server]。
SourceFactories mockFactories(MockServer server) {
  DioSourceHttpClient http(SourceManifest m) => DioSourceHttpClient(
    networkConfigFromManifest(m),
    adapter: mockAdapter(server),
  );
  return SourceFactories([
    DeclarativeSourceFactory(httpClientFor: http, log: (_) {}),
    ScriptSourceFactory(
      storage: MemorySourceStorage(),
      httpClientFor: http,
      log: (_) {},
    ),
  ]);
}

/// 一个最小的声明式清单（只用于注册表；运行时由 [FakeFactory] 接管）。
String fakeManifestJson(
  String id, {
  String? name,
  String version = '1.0.0',
  MediaType type = MediaType.comic,
}) => jsonEncode({
  'apiVersion': 1,
  'id': id,
  'name': name ?? id,
  'type': type.name,
  'version': version,
  'baseUrl': 'https://example.com',
  'engine': 'declarative',
  'rules': {
    'search': {
      'request': {'url': '/s?q={{keyword}}'},
      'list': 'css:li',
      'fields': {'id': 'css:a@href', 'title': 'css:a@text'},
    },
  },
});

class FakeSource implements DisposableSource {
  FakeSource(this.manifest, {this.onSearch, this.onDetail});

  @override
  final SourceManifest manifest;
  final Future<PageResult<SearchItem>> Function(String keyword, int page)?
  onSearch;
  final Future<Detail> Function(String id)? onDetail;

  final searches = <(String, int)>[];
  final details = <String>[];
  bool disposed = false;

  @override
  Future<PageResult<SearchItem>> search(String keyword, int page) {
    searches.add((keyword, page));
    return onSearch?.call(keyword, page) ??
        Future.value(const PageResult(items: [], hasMore: false));
  }

  @override
  Future<Detail> detail(String id) {
    details.add(id);
    return onDetail?.call(id) ??
        Future.error(const SourceException(SourceErrorCode.unsupported));
  }

  @override
  Future<List<ExploreCategory>> explore() =>
      Future.error(const SourceException(SourceErrorCode.unsupported));

  @override
  Future<PageResult<SearchItem>> exploreList(String categoryId, int page) =>
      Future.error(const SourceException(SourceErrorCode.unsupported));

  @override
  Future<MediaContent> content(String unitId) =>
      Future.error(const SourceException(SourceErrorCode.unsupported));

  @override
  void dispose() => disposed = true;
}

/// 按清单 id 用 [build] 构造 [FakeSource]，记录所有创建出的实例。
class FakeFactory implements SourceFactory {
  FakeFactory([this.build]);

  final FakeSource Function(SourceManifest manifest)? build;
  final created = <FakeSource>[];

  @override
  SourceEngine get engine => SourceEngine.declarative;

  @override
  Future<Source> create(SourceManifest manifest) async {
    final s = build?.call(manifest) ?? FakeSource(manifest);
    created.add(s);
    return s;
  }
}
