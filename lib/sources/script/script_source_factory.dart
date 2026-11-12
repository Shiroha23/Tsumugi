import 'dart:developer' as developer;

import '../../core/network/dio_source_http_client.dart';
import '../../core/network/source_http_client.dart';
import '../../core/storage/source_storage.dart';
import '../model/common.dart';
import '../model/manifest.dart';
import '../network_error_mapping.dart';
import '../registry/source_factory.dart';
import '../source.dart';
import 'script_source.dart';

/// 由清单创建本源独立的 HTTP 客户端（独立 Cookie 域、限速、白名单）。
typedef SourceHttpClientBuilder = SourceHttpClient Function(
  SourceManifest manifest,
);

SourceHttpClient _defaultHttp(SourceManifest manifest) =>
    DioSourceHttpClient(networkConfigFromManifest(manifest));

void _defaultLog(String message) =>
    developer.log(message, name: 'tsumugi.script');

/// `engine: "script"` 的 [SourceFactory]。创建的 [ScriptSource] 由调用方负责 `dispose`。
class ScriptSourceFactory implements SourceFactory {
  ScriptSourceFactory({
    required this.storage,
    this.httpClientFor = _defaultHttp,
    this.ui = const UnavailableScriptUi(log: _defaultLog),
    this.log = _defaultLog,
  });

  final SourceStorage storage;
  final SourceHttpClientBuilder httpClientFor;
  final ScriptUi ui;
  final void Function(String message) log;

  @override
  SourceEngine get engine => SourceEngine.script;

  @override
  Future<Source> create(SourceManifest manifest) => ScriptSource.create(
    manifest: manifest,
    http: httpClientFor(manifest),
    storage: storage,
    ui: ui,
    log: log,
  );
}
