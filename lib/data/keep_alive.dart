/// DSH 工作台 —— 后台保活（前台服务）。
///
/// 原生侧是 `KeepAliveService.kt`：一个常驻前台服务 + 一条低优先级通知。
/// 有了它，App 切到后台后进程不会被低内存回收/冻结，SSE 长连接能一直挂着。
///
/// 退出方式只有两种（用户明确要求）：
///   1. 从「最近任务」里划掉（系统会连服务一起收走）；
///   2. 系统设置里强行停止。
/// App 内的返回键被 main.dart 的 PopScope 拦住，永远不会退出。
library;

import 'package:flutter/services.dart';

class KeepAlive {
  static const MethodChannel _ch =
      MethodChannel('com.dsh.flutter_workbench/keepalive');

  /// 启动前台服务（幂等）。
  ///
  /// 失败不影响主功能：服务起不来只是退化成普通后台进程，
  /// 长连接仍可用，只是更容易被系统回收。所以这里**不抛异常**。
  static Future<bool> start() async {
    try {
      final ok = await _ch.invokeMethod<bool>('start');
      return ok ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 停止服务（正常流程不会调用，留给「彻底退出」用）。
  static Future<void> stop() async {
    try {
      await _ch.invokeMethod<void>('stop');
    } catch (_) {
      // 忽略：停不掉也不影响什么
    }
  }

  static Future<bool> isRunning() async {
    try {
      return await _ch.invokeMethod<bool>('isRunning') ?? false;
    } catch (_) {
      return false;
    }
  }
}
