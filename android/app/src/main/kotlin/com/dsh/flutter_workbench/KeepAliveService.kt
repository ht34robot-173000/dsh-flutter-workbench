package com.dsh.flutter_workbench

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * 常驻前台服务：让 App 退到后台之后**不被系统回收**。
 *
 * 为什么要它：DSH 工作台的核心是那条 SSE 长连接（`/rw/api/live`）。
 * 普通后台进程在 Android 上随时可能被内存回收或冻结 —— 一旦被冻，
 * 连接断掉、任务跑完了也收不到通知，用户切回来看到的是「掉线」。
 * 前台服务带一个常驻通知，进程获得更高的 oom_adj 优先级，能一直在后台跑。
 *
 * 为什么不用 flutter_foreground_task 之类的插件：
 *   这个需求只有「起一个常驻服务 + 一个通知」两件事，自己写 60 行足够，
 *   不用为它多背一个依赖和它的构建风险（本项目的建包已经在 6G 显存机器上
 *   跑过一次 Gradle 依赖地狱）。
 *
 * 退出方式：只能从「最近任务」里划掉（或在系统设置里强行停止）。
 * App 内的返回键被 Dart 侧的 PopScope 拦住了，不会退出（见 main.dart）。
 */
class KeepAliveService : Service() {

    companion object {
        private const val CHANNEL_ID = "dsh_keepalive"
        private const val NOTIFICATION_ID = 4711
        private const val ACTION_START = "com.dsh.flutter_workbench.KEEPALIVE_START"
        private const val ACTION_STOP = "com.dsh.flutter_workbench.KEEPALIVE_STOP"

        /** 启动（幂等：重复调用只是重新 startService）。 */
        fun start(ctx: Context) {
            val i = Intent(ctx, KeepAliveService::class.java).setAction(ACTION_START)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                ctx.startForegroundService(i)
            } else {
                ctx.startService(i)
            }
        }

        fun stop(ctx: Context) {
            val i = Intent(ctx, KeepAliveService::class.java).setAction(ACTION_STOP)
            ctx.startService(i)
        }
    }

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        // 必须先 startForeground，否则 Android 8+ 会抛
        // RemoteServiceException: Context.startForegroundService() did not then call Service.startForeground()
        startForeground(NOTIFICATION_ID, buildNotification())
        // START_STICKY：被系统杀掉后自动重建（重建时 intent 为 null，也要重新 startForeground）
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (mgr.getNotificationChannel(CHANNEL_ID) != null) return

        val ch = NotificationChannel(
            CHANNEL_ID,
            "后台运行",
            // LOW：不响、不弹、不亮屏，只在通知栏里躺着一条常驻项
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "保持与电脑的连接，后台也能收到任务进度"
            setShowBadge(false)
            enableVibration(false)
            enableLights(false)
        }
        mgr.createNotificationChannel(ch)
    }

    private fun buildNotification(): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher_monochrome)
            .setContentTitle("DSH 工作台正在运行")
            .setContentText("保持与电脑的连接；要退出请从最近任务里划掉")
            .setOngoing(true)          // 划不掉，只能停服务
            .setShowWhen(false)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(open)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }
}
