/// DSH 工作台 —— 安装器封装。
///
/// 走自定义 MethodChannel，对应 `MainActivity.kt` 里的三条通道。
///
/// ⚠️ 为什么不用 open_filex：
/// 它自带的 FileProvider authority 是
/// `{packageName}.fileProvider.com.crazecoder.openfile`，
/// 而 paths 只覆盖它自己的目录，**不包含 `cacheDir/updates/`**。
/// 复用它要么改它的 paths（编译进 AAR，改不动），
/// 要么把 APK 挪到它的目录里（语义混乱）。
///
/// ⚠️ 为什么必须查 canInstall：
/// Android 8.0+ 没授权「安装未知应用」时，系统安装器会
/// **启动后立刻被杀**，界面上什么都不出现 ——
/// 用户只看到「点了安装但没反应」。所以调用前必须先查、并引导授权。
library;

import 'dart:io';

import 'package:flutter/services.dart';

class Installer {
  static const _ch = MethodChannel('com.dsh.flutter_workbench/updater');

  /// 是否已获得「安装未知应用」权限。
  ///
  /// 非 Android 平台恒为 false（这个 App 只有 Android，但别崩）。
  static Future<bool> canInstall() async {
    if (!Platform.isAndroid) return false;
    try {
      final r = await _ch.invokeMethod<bool>('canInstall');
      return r ?? false;
    } catch (_) {
      // 通道没注册（比如改了原生侧但没重编）时不要崩，当作没权限
      return false;
    }
  }

  /// 跳系统设置里「安装未知应用」那一页。
  static Future<void> openInstallSettings() async {
    if (!Platform.isAndroid) return;
    try {
      await _ch.invokeMethod<void>('openInstallSettings');
    } catch (_) {}
  }

  /// 拿应用私有 `cacheDir` 的绝对路径。
  ///
  /// ⚠️ 不能用 `Directory.systemTemp` —— 它在 Android 上映射到 **code_cache**，
  /// 不是 cacheDir。而 FileProvider 的 `cache-path` 只能映射 cacheDir，
  /// 两者对不上就会在拉起安装器时报：
  ///
  ///   IllegalArgumentException: Failed to find configured root
  ///   that contains `/data/data/{pkg}/code_cache/updates/xxx.apk`
  ///
  /// 表现是「下载成功，点安装瞬间失败」。
  ///
  /// 所以目录一律从原生问，保证和 file_paths.xml 严格一致。
  static Future<String?> cacheDirPath() async {
    if (!Platform.isAndroid) return null;
    try {
      return await _ch.invokeMethod<String>('cacheDir');
    } catch (_) {
      return null;
    }
  }

  /// 用系统安装器装上指定 APK。
  ///
  /// 返回 `null` 表示成功调起；返回字符串表示失败原因。
  static Future<String?> installApk(String path) async {
    if (!Platform.isAndroid) return '当前平台不支持';
    try {
      await _ch.invokeMethod<bool>('installApk', {'path': path});
      return null;
    } on PlatformException catch (e) {
      return e.message ?? e.code;
    } catch (e) {
      return '$e';
    }
  }
}
