import 'dart:convert';
import 'dart:io';

import 'package:tsumugi/core/engine/declarative/fetcher.dart';
import 'package:tsumugi/sources/model/manifest.dart';

const fixtureRoot = 'test/fixtures/declarative';

SourceManifest loadManifest(String name) => SourceManifest.fromJson(
  jsonDecode(File('$fixtureRoot/$name/source.json').readAsStringSync())
      as Map<String, dynamic>,
);

/// 内存中的假网络：把 `METHOD url` 映射到 `test/fixtures/declarative/` 下的文件。
/// 未注册的地址返回 404。
class FixtureFetcher implements Fetcher {
  FixtureFetcher(this.routes);

  /// 键为 `GET https://...`，值为相对 [fixtureRoot] 的文件路径。
  final Map<String, String> routes;
  final requests = <FetchRequest>[];

  @override
  Future<FetchResponse> fetch(FetchRequest request) async {
    requests.add(request);
    final file = routes['${request.method} ${request.url}'];
    if (file == null) {
      return FetchResponse(status: 404, url: request.url, body: 'not found');
    }
    return FetchResponse(
      status: 200,
      url: request.url,
      body: File('$fixtureRoot/$file').readAsStringSync(),
    );
  }
}
