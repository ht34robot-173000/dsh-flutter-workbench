package com.dsh.flutter_workbench

import android.app.ActivityManager
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 原生侧：一条是应用内更新（FileProvider 拉起安装器），一条是后台保活（前台服务）。
 *
 * 更新为什么不用 open_filex：它自带的 FileProvider authority 是
 * `{packageName}.fileProvider.com.crazecoder.openfile`，paths 只覆盖
 * 它自己的目录，**不包含我们下载 APK 的 `cacheDir/updates/`**。
 * 复用它要么改它的 paths（改不动，是编译进 AAR 的），
 * 要么把 APK 挪到它的目录里（语义混乱）。
 *
 * Android 7+ 直接传 file:// 会抛 FileUriExposedException，必须走 content://；
 * Android 8+ 还需要用户单独授权「安装未知应用」，没授权时安装器会
 * **启动后立刻被杀**，界面上什么都不出现 —— 所以调用前必须查 canInstall。
 *
 * 保活为什么自己写而不引插件：只需要「常驻服务 + 一条通知」，
 * 60 行足够，不值得为它多背一个依赖和它的构建风险。
 */
class MainActivity : FlutterActivity() {

    private val updaterChannel = "com.dsh.flutter_workbench/updater"
    private val keepAliveChannel = "com.dsh.flutter_workbench/keepalive"

    /** Android 13+ 的通知权限请求码（前台服务的常驻通知要它才算完整）。 */
    private val notifPermCode = 0x1001

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        /*
         * 后台保活通道：启 / 停 / 查三件事。
         *
         * 服务本体在 KeepAliveService.kt。顺带在 Android 13+ 上要一下通知权限 ——
         * 没授权服务照样能跑，只是通知栏里看不到常驻项（用户会以为后台没生效）。
         */
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, keepAliveChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        try {
                            requestNotificationPermissionIfNeeded()
                            KeepAliveService.start(this)
                            result.success(true)
                        } catch (e: Throwable) {
                            // 常见：Android 14 的 FGS 类型没声明、通知渠道建失败
                            result.error(
                                "keepalive-start-failed",
                                "${e.javaClass.simpleName}: ${e.message}",
                                null,
                            )
                        }
                    }

                    "stop" -> {
                        try {
                            KeepAliveService.stop(this)
                            result.success(null)
                        } catch (e: Throwable) {
                            result.error("keepalive-stop-failed", e.message, null)
                        }
                    }

                    "isRunning" -> result.success(isServiceRunning())

                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, updaterChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "canInstall" -> result.success(canInstall())

                    /*
                     * 返回 cacheDir 的绝对路径。
                     *
                     * 为什么让原生给：Dart 的 `Directory.systemTemp` 在 Android 上
                     * 映射到 **code_cache**，而 FileProvider 的 `cache-path`
                     * 只能映射 cacheDir —— 两者对不上会让安装器报
                     * 「Failed to find configured root」。
                     *
                     * 目录必须和 res/xml/file_paths.xml 的映射严格一致，
                     * 所以从这一侧给，避免 Dart 猜错。
                     */
                    "cacheDir" -> result.success(cacheDir.absolutePath)

                    "openInstallSettings" -> {
                        openInstallSettings()
                        result.success(null)
                    }

                    "installApk" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrEmpty()) {
                            result.error("bad-args", "缺少 path", null)
                            return@setMethodCallHandler
                        }
                        val f = File(path)
                        if (!f.exists() || !f.isFile) {
                            result.error("not-found", "APK 不存在：$path", null)
                            return@setMethodCallHandler
                        }
                        try {
                            installApk(f)
                            result.success(true)
                        } catch (e: Throwable) {
                            // 常见：没权限、FileProvider 没配、URI 不匹配
                            result.error(
                                "install-failed",
                                "${e.javaClass.simpleName}: ${e.message}",
                                null,
                            )
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    /** 简单判活：服务在运行就返回 true。 */
    private fun isServiceRunning(): Boolean {
        val mgr = getSystemService(ActivityManager::class.java) ?: return false
        @Suppress("DEPRECATION")
        val services = mgr.getRunningServices(Int.MAX_VALUE)
        return services.any { it.service.className == KeepAliveService::class.java.name }
    }

    /** Android 13+ 才有的运行时通知权限。 */
    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val granted =
            checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED
        if (!granted) {
            requestPermissions(
                arrayOf(android.Manifest.permission.POST_NOTIFICATIONS),
                notifPermCode,
            )
        }
    }

    /** 是否已获得「安装未知应用」权限。Android 8.0 以下恒为 true。 */
    private fun canInstall(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            packageManager.canRequestPackageInstalls()
        } else {
            true
        }
    }

    /**
     * 跳到「安装未知应用」授权页。
     *
     * 优先直接跳到本应用那一页；某些 ROM 没有这一页，
     * 退回应用详情页。
     */
    private fun openInstallSettings() {
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName"))
        } else {
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName"))
        }.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

        try {
            startActivity(intent)
        } catch (_: Throwable) {
            try {
                startActivity(
                    Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName"))
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                )
            } catch (_: Throwable) {
                // 都失败就什么都不做 —— Dart 侧已经提示用户手动去开
            }
        }
    }

    /** 用 FileProvider 把 cacheDir/updates/ 下的 APK 交给系统安装器。 */
    private fun installApk(apk: File) {
        // authority 必须和 AndroidManifest 里 provider 的 authorities 一致
        val authority = "$packageName.fileprovider"
        val uri = FileProvider.getUriForFile(this, authority, apk)

        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
    }
}
