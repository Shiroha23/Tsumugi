import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// 后台下载（architecture §4.5.1，#74）：进入后台后用尽系统给的宽限时间（beginBackgroundTask），
  /// 到期前由 Dart 把进行中的任务记为 queued 并暂停。iOS 没有常驻通知。
  private var downloadTask: UIBackgroundTaskIdentifier = .invalid
  private var downloadChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "TsumugiBackgroundDownload")
    else { return }
    let channel = FlutterMethodChannel(
      name: "io.github.tsumugi/background_download",
      binaryMessenger: registrar.messenger())
    downloadChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(nil)
        return
      }
      switch call.method {
      case "beginBackgroundTask":
        result(self.beginDownloadTask())
      case "endBackgroundTask":
        self.endDownloadTask()
        result(nil)
      case "show", "hide", "requestNotificationPermission":
        // Android 专用（前台服务与通知）。
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// 开始后台任务，返回剩余的宽限时间（秒）。
  private func beginDownloadTask() -> Double {
    if downloadTask == .invalid {
      downloadTask = UIApplication.shared.beginBackgroundTask(withName: "downloads") { [weak self] in
        // 到期：先让 Dart 挂起队列（把进行中的任务记为 queued），它回复后再结束任务；
        // Dart 来不及回复时 1 s 后无论如何结束（不结束会被系统终止）。回到前台时 Dart 还会修正残留的 running。
        guard let self = self else { return }
        self.downloadChannel?.invokeMethod("expiring", arguments: nil) { _ in
          self.endDownloadTask()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
          self.endDownloadTask()
        }
      }
    }
    if downloadTask == .invalid { return 0 }
    let remaining = UIApplication.shared.backgroundTimeRemaining
    // 刚进入后台时可能仍是“无限”（DBL_MAX）：按系统通常给的约 30 s 估计。
    return remaining > 600 ? 25 : remaining
  }

  private func endDownloadTask() {
    guard downloadTask != .invalid else { return }
    UIApplication.shared.endBackgroundTask(downloadTask)
    downloadTask = .invalid
  }
}
