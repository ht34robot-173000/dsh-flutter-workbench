/// DSH 工作台 —— 系统级操作（远程重启）。
///
/// 对接宿主：
///   POST /rw/api/system.restartStatus  → { platform, canRestart, reason, script, shellPid, shellExe, hostPid, hostUptimeMs, lastRestart }
///   POST /rw/api/system.restart        → 真的重启（拼 relaunch.ps1 的那套）
///
/// ⚠️ 重启**不能自己写一条链路**（交接文档第十节）：
/// 「杀外壳 → explorer 派发助手 → 拉起新实例」有三处必踩 ——
/// Electron 的 `KILL_ON_JOB_CLOSE`、`taskkill` 不带 `/F` 会被收进托盘、端口没释放就拉起。
/// 宿主的 `restart` 直接 spawn `dsh-seamless-restart/lib/relaunch.ps1`，这些都处理好了。
/// 客户端只负责「发一次请求 + 告诉用户等十几秒」。
library;

import 'ds_api.dart';

class RestartStatus {
  /// 宿主判断能不能重启（Windows + 找得到 relaunch.ps1 + 认得出外壳进程）。
  final bool canRestart;

  /// 不能重启时的原因码：`script-missing` / `unsupported-platform` / `desktop-shell` …
  final String? reason;

  /// 探测到的 relaunch.ps1 路径。
  final String? script;

  final String? shellExe;
  final int? hostPid;

  /// 宿主已经跑了多久（毫秒）。重启后这个数会归零，可以拿来「确认真的重启过」。
  final int? hostUptimeMs;

  /// 上一次重启的时间戳（毫秒）。
  final int? lastRestartAt;

  const RestartStatus({
    required this.canRestart,
    this.reason,
    this.script,
    this.shellExe,
    this.hostPid,
    this.hostUptimeMs,
    this.lastRestartAt,
  });

  /// 给人看的原因。
  String get reasonText {
    switch (reason) {
      case 'desktop-shell':
        return '可以重启（桌面版外壳已识别）';
      case 'script-missing':
        return '找不到 dsh-seamless-restart 的 relaunch.ps1';
      case 'unsupported-platform':
        return '远程重启只支持 Windows 桌面版';
      case null:
        return canRestart ? '可以重启' : '当前不可重启';
      default:
        return reason!;
    }
  }

  static RestartStatus fromValue(Map<String, dynamic>? v) {
    final last = v?['lastRestart'];
    return RestartStatus(
      canRestart: v?['canRestart'] == true,
      reason: _str(v?['reason']),
      script: _str(v?['script']),
      shellExe: _str(v?['shellExe']),
      hostPid: _int(v?['hostPid']),
      hostUptimeMs: _int(v?['hostUptimeMs']),
      lastRestartAt: last is Map ? _int(last['at']) : null,
    );
  }

  static String? _str(Object? o) {
    final s = (o ?? '').toString().trim();
    return s.isEmpty ? null : s;
  }

  static int? _int(Object? o) => o is num ? o.toInt() : int.tryParse('${o ?? ''}');
}

class SystemApi {
  final DshApi api;
  SystemApi(this.api);

  Future<(ApiResult, RestartStatus?)> restartStatus() async {
    final r = await api.api('system.restartStatus');
    if (!r.ok) return (r, null);
    final v = r.value?['value'];
    return (r, RestartStatus.fromValue(v is Map ? v.cast<String, dynamic>() : null));
  }

  /// 请求重启。成功返回时宿主**还没**退 —— 它只是把助手脚本派出去了。
  /// 客户端要自己等十几秒并重连。
  Future<ApiResult> restart() => api.api('system.restart');
}
