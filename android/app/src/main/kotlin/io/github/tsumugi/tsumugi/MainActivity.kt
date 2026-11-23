package io.github.tsumugi.tsumugi

import android.Manifest
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private val main = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 后台下载（architecture §4.5.1，#74）：Dart 的下载队列 ↔ 前台服务 DownloadService。
        val ch = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "io.github.tsumugi/background_download",
        )
        channel = ch
        DownloadService.listener = { event ->
            main.post { channel?.invokeMethod(event, null) }
        }
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "show" -> {
                    show(
                        call.argument<String>("text") ?: "",
                        call.argument<Int>("progress") ?: -1,
                    )
                    result.success(null)
                }
                "hide" -> {
                    stopService(Intent(this, DownloadService::class.java))
                    result.success(null)
                }
                "requestNotificationPermission" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                        checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
                        PackageManager.PERMISSION_GRANTED
                    ) {
                        // 拒绝时仍可下载，只是没有通知。
                        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 7401)
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun show(text: String, progress: Int) {
        if (DownloadService.running) {
            // 已在前台：只更新通知（从后台再次启动前台服务会被系统拒绝）。
            getSystemService(NotificationManager::class.java).notify(
                DownloadService.NOTIFICATION_ID,
                DownloadService.build(this, text, progress),
            )
            return
        }
        val intent = Intent(this, DownloadService::class.java)
            .setAction(DownloadService.ACTION_UPDATE)
            .putExtra(DownloadService.EXTRA_TEXT, text)
            .putExtra(DownloadService.EXTRA_PROGRESS, progress)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
        } catch (e: RuntimeException) {
            // Android 12+ 不允许从后台启动前台服务（ForegroundServiceStartNotAllowedException）、
            // 或当日 dataSync 时限已用完：下载照常在前台进行。
            android.util.Log.w("Tsumugi", "download service not started: $e")
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        channel?.setMethodCallHandler(null)
        channel = null
        DownloadService.listener = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onDestroy() {
        // 界面被销毁时 Flutter 引擎随之销毁，下载也停止：不留下空转的前台服务。
        if (isFinishing) stopService(Intent(this, DownloadService::class.java))
        super.onDestroy()
    }
}
