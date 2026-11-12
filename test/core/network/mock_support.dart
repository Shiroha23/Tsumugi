import 'dart:io';

import 'package:dio/io.dart';
import 'package:tsumugi/core/network/dio_source_http_client.dart';
import 'package:tsumugi/core/network/source_http_client.dart';
import 'package:tsumugi/core/network/source_session.dart';

import '../../../tool/mock_server/mock_server.dart';

export '../../../tool/mock_server/mock_server.dart';

/// 把任意（虚构）主机名的连接都接到本地 [server]，这样测试可以使用
/// `comic.example.com` 之类的地址，同时白名单检查仍按真实主机名进行。
IOHttpClientAdapter mockAdapter(MockServer server) => IOHttpClientAdapter(
  createHttpClient: () =>
      HttpClient()
        ..connectionFactory = (uri, proxyHost, proxyPort) =>
            Socket.startConnect(InternetAddress.loopbackIPv4, server.port),
);

DioSourceHttpClient mockClient(
  MockServer server, {
  String sourceId = 'com.example.comic',
  String baseUrl = 'http://comic.example.com',
  List<String> allowedHosts = const ['img.example.com'],
  Map<String, String> headers = const {},
  Duration timeout = const Duration(seconds: 5),
  RateLimitConfig? rateLimit,
  int maxRetries = 2,
  int maxRedirects = 5,
  int maxResponseBytes = 20 * 1024 * 1024,
  SourceSession? session,
}) => DioSourceHttpClient(
  SourceNetworkConfig(
    sourceId: sourceId,
    baseUrl: Uri.parse(baseUrl),
    allowedHosts: allowedHosts,
    defaultHeaders: headers,
    timeout: timeout,
    rateLimit: rateLimit,
    maxRetries: maxRetries,
    retryBaseDelay: const Duration(milliseconds: 10),
    maxRedirects: maxRedirects,
    maxResponseBytes: maxResponseBytes,
  ),
  adapter: mockAdapter(server),
  session: session,
);
