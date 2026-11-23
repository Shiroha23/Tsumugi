package io.github.tsumugi.tsumugi

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.os.Build
import android.os.IBinder

/**
 * 下载队列的前台服务（architecture §4.5.1「后台下载」，#74）。
 *
 * 下载本身仍在 Dart 中执行（同一个 isolate 与网络层），本服务只让进程保持前台优先级，
 * 并显示常驻通知（总进度与「暂停全部」）。队列清空或全部暂停时由 Dart 停止。
 *
 * Android 15 起 `dataSync` 前台服务每天累计限 6 小时：到时系统调用 [onTimeout]，
 * 本服务通知 Dart（挂起队列，回到前台继续）并立即停止。
 */
class DownloadService : Service() {
    companion object {
        const val ACTION_UPDATE = "io.github.tsumugi.download.UPDATE"
        const val ACTION_PAUSE_ALL = "io.github.tsumugi.download.PAUSE_ALL"
        const val EXTRA_TEXT = "text"
        const val EXTRA_PROGRESS = "progress"
        private const val CHANNEL_ID = "downloads"
        const val NOTIFICATION_ID = 1001

        /** 通知中的「暂停全部」、系统时限到：转给 Dart（由 MainActivity 设置）。 */
        var listener: ((String) -> Unit)? = null

        /** 服务已进入前台。由服务在 startForeground 成功后置 true；MainActivity 停止服务时同步置 false。 */
        @Volatile
        var running = false

        fun ensureChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val manager = context.getSystemService(NotificationManager::class.java)
            if (manager.getNotificationChannel(CHANNEL_ID) != null) return
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "下载", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "下载进度"
                    setShowBadge(false)
                },
            )
        }

        fun build(context: Context, text: String, progress: Int): Notification {
            ensureChannel(context)
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(context, CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(context)
            }
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            val open = PendingIntent.getActivity(
                context,
                0,
                Intent(context, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                flags,
            )
            val pause = PendingIntent.getService(
                context,
                1,
                Intent(context, DownloadService::class.java).setAction(ACTION_PAUSE_ALL),
                flags,
            )
            builder
                .setSmallIcon(android.R.drawable.stat_sys_download)
                .setContentTitle("Tsumugi 正在下载")
                .setContentText(text)
                .setContentIntent(open)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setShowWhen(false)
            if (progress in 0..1000) {
                builder.setProgress(1000, progress, false)
            } else {
                builder.setProgress(0, 0, true)
            }
            builder.addAction(
                Notification.Action.Builder(
                    Icon.createWithResource(context, android.R.drawable.ic_media_pause),
                    "暂停全部",
                    pause,
                ).build(),
            )
            return builder.build()
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_PAUSE_ALL -> {
                listener?.invoke("pauseAll")
                // 服务原本不在前台（例如刚被停止）：这次是作为普通服务被启动的，处理完即停止。
                if (!running) stopSelf(startId)
                return START_NOT_STICKY
            }
            else -> {
                val text = intent?.getStringExtra(EXTRA_TEXT) ?: ""
                val progress = intent?.getIntExtra(EXTRA_PROGRESS, -1) ?: -1
                val notification = build(this, text, progress)
                try {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        startForeground(
                            NOTIFICATION_ID,
                            notification,
                            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
                        )
                    } else {
                        startForeground(NOTIFICATION_ID, notification)
                    }
                    running = true
                } catch (e: RuntimeException) {
                    // Android 12+ 已转到后台（ForegroundServiceStartNotAllowedException）、
                    // Android 15 当日 dataSync 时限已用完等：不进入前台，通知 Dart 并停止。
                    android.util.Log.w("Tsumugi", "startForeground failed: $e")
                    running = false
                    listener?.invoke("unavailable")
                    stopSelf()
                }
            }
        }
        // 进程被杀后不由系统重启：下载在 Dart 中，重启服务没有意义。
        return START_NOT_STICKY
    }

    /** Android 15+：`dataSync` 每日时限到。 */
    override fun onTimeout(startId: Int, fgsType: Int) {
        listener?.invoke("timeout")
        stopSelf()
    }

    /** 从最近任务中划掉：Flutter 引擎随界面销毁，下载已停止，不留下空转的服务与通知。 */
    override fun onTaskRemoved(rootIntent: Intent?) {
        running = false
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        running = false
        super.onDestroy()
    }
}
