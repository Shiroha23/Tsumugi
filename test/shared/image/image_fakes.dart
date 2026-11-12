import 'dart:convert';
import 'dart:typed_data';

import 'package:tsumugi/core/network/source_http_client.dart';

/// 1×1 PNG（与 tool/mock_server 相同的虚构图片）。
final png1x1 = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
);

class FakeImageClient implements SourceHttpClient {
  FakeImageClient(this.body);

  Uint8List Function(String url) body;
  final requests = <NetRequest>[];

  @override
  Future<NetResponse> request(NetRequest request) async {
    requests.add(request);
    return NetResponse(
      status: 200,
      url: Uri.parse(request.url),
      headersAll: const {
        'content-type': ['image/png'],
      },
      bytes: body(request.url),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
