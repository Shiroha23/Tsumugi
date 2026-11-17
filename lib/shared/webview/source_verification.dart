import '../../sources/model/manifest.dart';
import '../../sources/network_error_mapping.dart';
import '../../sources/source.dart';
import '../../sources/registry/providers.dart';
import '../../sources/runtime/source_runtime.dart';
import '../../sources/session/source_sessions.dart';
import 'source_verifier.dart';
import 'webview_models.dart';

/// 界面上「打开验证页」的入口（`SourceErrorView`、阅读器错误页）。
abstract interface class SourceVerification {
  /// 为 [sourceId] 打开验证页（用户主动发起，不受频率限制）。
  ///
  /// 用户完成、Cookie 已写回时返回 true；取消时返回 false。
  /// 源不可用时抛出 [SourceUnavailableException]，其他失败抛出 `SourceException`。
  Future<bool> verifySource(String sourceId);

  /// 源菜单「登录 / 打开网页」：为 [sourceId] 打开清单的 `loginUrl`（缺省 `baseUrl`）。
  ///
  /// 流程与 [verifySource] 相同（用户主动发起，不受频率限制），返回值与异常也相同；
  /// 地址不在白名单内时抛出 [SourceErrorCode.hostNotAllowed] 的 `SourceException`。
  Future<bool> openLoginPage(String sourceId);
}

/// 默认实现：从注册表读取清单，打开最近一次检测到挑战的地址（没有时为 `baseUrl`）。
class RegistrySourceVerification implements SourceVerification {
  RegistrySourceVerification({
    required this.registry,
    required this.sessions,
    required this.verifier,
  });

  final SourceRegistry registry;
  final SourceSessions sessions;
  final SourceVerifier verifier;

  Future<(InstalledSource, SourceManifest)> _load(String sourceId) async {
    final installed = await registry.get(sourceId);
    final manifest = installed?.manifest;
    if (installed == null || manifest == null) {
      throw SourceUnavailableException(sourceId, '源未安装或清单不可用');
    }
    return (installed, manifest);
  }

  @override
  Future<bool> verifySource(String sourceId) async {
    final (installed, manifest) = await _load(sourceId);
    final config = networkConfigFromManifest(manifest);
    final session = sessions.of(sourceId);
    final last = session.lastChallengeUrl;
    final url = last != null && config.hostPolicy.isAllowed(last)
        ? last
        : config.baseUrl;
    return verifier.verify(
      VerificationRequest.fromConfig(
        config,
        url: url,
        title: '${installed.name} · 验证 / 登录',
      ),
      session,
      userInitiated: true,
    );
  }

  @override
  Future<bool> openLoginPage(String sourceId) async {
    final (installed, manifest) = await _load(sourceId);
    final config = networkConfigFromManifest(manifest);
    final url = manifest.loginUri;
    // 清单校验已保证 loginUrl 在白名单内；这里再检查一次，不依赖调用方。
    if (url == null || !config.hostPolicy.isAllowed(url)) {
      throw const SourceException(
        SourceErrorCode.hostNotAllowed,
        'loginUrl 不在该源的白名单内',
      );
    }
    return verifier.verify(
      VerificationRequest.fromConfig(
        config,
        url: url,
        title: '${installed.name} · 登录',
      ),
      sessions.of(sourceId),
      userInitiated: true,
    );
  }
}
