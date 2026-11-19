package com.dsh.flutter_workbench

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 应用内更新的原生侧。
 *
 * 为什么不用 open_filex：它自带的 FileProvider authority 是
 * `{packageName}.fileProvider.com.crazecoder.openfile`，paths 只覆盖
 * 它自己的目录，**不包含我们下载 APK 的 `cacheDir/updates/`**。
 * 复用它要么改它的 paths（改不动，是编译进 AAR 的），
 * 要么把 APK 挪到它的目录里（语义混乱）。
 *
 * 所以自己走一个 MethodChannel，三条通道：
 *   canInstall      → 查「安装未知应用」权限
 *   openInstallSettings → 跳到授权页
 *   installApk      → 用我们的 FileProvider 拉起系统安装器
 *
 * Android 7+ 直接传 file:// 会抛 FileUriExposedException，
 * 必须走 content:// + FLAG_GRANT_READ_URI_PERMISSION。
 * Android 8+ 还需要用户在设置里单独授权「安装未知应用」，
 * 没授权时安装器会**启动后立刻被杀**，界面上什么都不出现 ——
 * 所以调用前必须查 canInstall。
 */
class MainActivity : FlutterActivity() {

    private val channelName = "com.dsh.flutter_workbench/updater"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
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
