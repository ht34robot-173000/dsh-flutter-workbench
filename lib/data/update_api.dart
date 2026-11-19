/// DSH 工作台 —— 应用内更新数据层。
///
/// 逻辑照 Kotlin 版 `Updater.kt`（已真机验证过），改写成 Dart。
///
/// ⚠️ 四条关键约束：
///
///  1. **`api.github.com` 在国内可能完全不可达**。
///     本机实测：`Resolve-DnsName api.github.com` 返回 **127.0.0.1**
///     —— DNS 被污染/劫持，连接直接被拒。
///     所以 API 端点必须**可配置**，不能硬编码一个域名。
///
///  2. **APK 下载必须走镜像**。Kotlin 版真机日志的决定性证据：
///     `DNS_CACHE: hostname:github.com, result_code:408`（解析超时），
///     实测 gh-proxy.com 比直连快 11 倍。
///     所以下载候选用「镜像优先 + 直连兜底」。
///
///  3. **`TOKEN` 恒为空，绝不能在源码里写死凭据**。
///     2026-11-16 事故：硬编码 `ghp_...` 全权限 token 随 APK 分发，
///     GitHub 账号被停用、仓库 404。这条绝对不能重演。
///
///  4. **Android 禁止静默安装自己**。下载完只能拉起系统安装器，
///     由用户点「安装」。任何声称能绕过的方法都要利用系统漏洞。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 一次版本检查的结果。
class UpdateInfo {
  /// 是否有新版本。
  final bool hasUpdate;

  /// 当前版本名（来自 PackageInfo）。
  final String currentVersion;

  /// 远端最新版本名（去掉开头的 `v`）。
  final String latestVersion;

  /// APK 直链（GitHub 原始地址）。
  final String downloadUrl;

  /// APK 大小（字节）。0 表示未知。
  final int sizeBytes;

  /// 更新说明（release body），可能为空。
  final String releaseNotes;

  /// 出错信息。null 表示查询成功。
  final String? error;

  const UpdateInfo({
    this.hasUpdate = false,
    this.currentVersion = '',
    this.latestVersion = '',
    this.downloadUrl = '',
    this.sizeBytes = 0,
    this.releaseNotes = '',
    this.error,
  });

  bool get ok => error == null;
}

/// 比较语义版本。`>0` 表示 a 比 b 新。
///
/// 只按数字段比：`2.10 > 2.9`（字符串比较做不到这个）。
/// 段数不同时短的补 0（`2.1 == 2.1.0`）。
int compareVersion(String a, String b) {
  final pa = a.split('.').map((x) => int.tryParse(x.trim()) ?? 0).toList();
  final pb = b.split('.').map((x) => int.tryParse(x.trim()) ?? 0).toList();
  final n = pa.length > pb.length ? pa.length : pb.length;
  for (var i = 0; i < n; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x - y;
  }
  return 0;
}

/// 把 GitHub 原始地址展开成「镜像优先 + 直连兜底」的候选列表。
///
/// 只对 github / githubusercontent 的地址套镜像 —— 其他域名保持原样
/// （比如自己搭的服务器就不该套）。
List<String> downloadCandidates(String original) {
  if (!original.contains('github.com') &&
      !original.contains('githubusercontent.com')) {
    return [original];
  }
  final list = githubMirrors.map((m) => '$m$original').toList();
  list.add(original); // 镜像全挂时回退直连
  return list;
}

/// 国内可用的 GitHub 下载镜像，按实测速度排序。
///
/// Kotlin 版真机实测 v3.x 的 2.21MB 包：
///   直连 github.com    76 KB/s   29.8s
///   gh-proxy.com      887 KB/s    2.6s   ← 快 11 倍
///   ghfast.top        438 KB/s    5.2s
const List<String> githubMirrors = [
  'https://gh-proxy.com/',
  'https://ghfast.top/',
  'https://ghproxy.net/',
  'https://gh.llkk.cc/',
];

class UpdateApi {
  /// 仓库全名。源码和 Release 同仓库，不容易漏发。
  static const String defaultRepo = 'ht34robot-173000/dsh-flutter-workbench';

  /// ✅ **恒为空。绝不要在源码里写死任何凭据。**
  static const String token = '';

  /// API 端点。可改，因为 `api.github.com` 在国内常常不可达。
  ///
  /// 本机实测解析到 127.0.0.1（DNS 污染）。
  /// 留一个可注入的口子，用户能填自己的反代。
  final String apiBase;

  /// 仓库全名，可在设置里改（fork 的人不用改源码）。
  final String repo;

  UpdateApi({
    this.apiBase = 'https://api.github.com',
    this.repo = defaultRepo,
  });

  HttpClient _client({Duration connect = const Duration(seconds: 15)}) {
    return HttpClient()
      ..connectionTimeout = connect
      ..idleTimeout = const Duration(seconds: 20)
      ..userAgent = 'dsh-flutter-workbench-updater';
  }

  /// 查询最新 release。
  ///
  /// `currentVersion` 由调用方传入（来自 PackageInfo）。
  Future<UpdateInfo> check(String currentVersion) async {
    /*
     * ⚠️ 先探仓库本身，再查 releases/latest。
     *
     * 为什么需要两步：GitHub 对**两种完全不同的情况都返回 404**：
     *   1. 仓库存在，但一个 release 都没发过  → 正常，「已是最新」
     *   2. 仓库不存在 / 账号被停用 / 改名      → **必须报错**
     *
     * 只看 releases/latest 的 404 会把第 2 种情况当成第 1 种，
     * 界面上显示「已是最新版本」—— 用户以为一切正常，实际是
     * 更新通道整个断了。这是典型的静默失败。
     *
     * 现实案例：2026-11-16 硬编码 token 事故后 GitHub 账号被停用，
     * 仓库 404，而客户端一直显示「已是最新」。
     */
    final repoCheck = await _probeRepo();
    if (repoCheck != null) {
      // 仓库层面就不可用，直接如实报错
      return UpdateInfo(currentVersion: currentVersion, error: repoCheck);
    }

    final url = Uri.parse('$apiBase/repos/$repo/releases/latest');
    HttpClient? c;
    try {
      c = _client();
      final req = await c.getUrl(url);
      req.headers.set('Accept', 'application/vnd.github+json');
      if (token.isNotEmpty) {
        req.headers.set('Authorization', 'Bearer $token');
      }
      final res = await req.close();

      if (res.statusCode == 404) {
        // 走到这里说明仓库存在（上一步验过了），只是还没发过 release
        return UpdateInfo(currentVersion: currentVersion, latestVersion: currentVersion);
      }
      if (res.statusCode != 200) {
        return UpdateInfo(
          currentVersion: currentVersion,
          error: 'GitHub 返回 HTTP ${res.statusCode}',
        );
      }

      final body = await res.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;

      final tag = (json['tag_name'] ?? '').toString().trim().replaceFirst(RegExp(r'^v'), '');
      if (tag.isEmpty) {
        return UpdateInfo(currentVersion: currentVersion, error: 'release 没有 tag_name');
      }

      var apkUrl = '';
      var size = 0;
      final assets = json['assets'];
      if (assets is List) {
        for (final a in assets) {
          if (a is! Map) continue;
          final name = (a['name'] ?? '').toString();
          if (name.toLowerCase().endsWith('.apk')) {
            // 公开仓库优先 browser_download_url：不需要 Authorization，
            // 走公开 CDN，不占 API 配额
            final direct = (a['browser_download_url'] ?? '').toString();
            apkUrl = direct.isNotEmpty ? direct : (a['url'] ?? '').toString();
            size = (a['size'] is num) ? (a['size'] as num).toInt() : 0;
            break;
          }
        }
      }

      final newer = compareVersion(tag, currentVersion) > 0;
      return UpdateInfo(
        hasUpdate: newer && apkUrl.isNotEmpty,
        currentVersion: currentVersion,
        latestVersion: tag,
        downloadUrl: apkUrl,
        sizeBytes: size,
        releaseNotes: (json['body'] ?? '').toString(),
        // 有新版本但没 APK 附件，要明确说，别静默失败
        error: (newer && apkUrl.isEmpty) ? '新版本没有附带 APK' : null,
      );
    } catch (e) {
      return UpdateInfo(
        currentVersion: currentVersion,
        error: _describeError(e),
      );
    } finally {
      c?.close(force: true);
    }
  }

  /// 探一下仓库本身是否可访问。
  ///
  /// 返回 `null` 表示仓库正常（可以继续查 release）；
  /// 返回字符串表示不可用的原因。
  ///
  /// 这一步专门用来区分「仓库 404」和「没有 release」——
  /// 两种情况在 `releases/latest` 上都是 404，但含义天差地别。
  Future<String?> _probeRepo() async {
    HttpClient? c;
    try {
      c = _client(connect: const Duration(seconds: 12));
      final req = await c.getUrl(Uri.parse('$apiBase/repos/$repo'));
      req.headers.set('Accept', 'application/vnd.github+json');
      if (token.isNotEmpty) {
        req.headers.set('Authorization', 'Bearer $token');
      }
      final res = await req.close();
      // 把 body 读完，否则连接不释放
      await res.drain<void>();

      switch (res.statusCode) {
        case 200:
          return null;
        case 404:
          return '仓库 $repo 不存在（账号被停用、改名或未公开）';
        case 401:
          return '访问被拒（401），仓库可能需要认证';
        case 403:
          return '被 GitHub 限流或封禁（403），稍后再试';
        default:
          return '仓库检查失败：HTTP ${res.statusCode}';
      }
    } catch (e) {
      return _describeError(e);
    } finally {
      c?.close(force: true);
    }
  }

  /// 把底层异常翻译成用户能看懂的话。
  String _describeError(Object e) {
    final s = e.toString();
    if (e is SocketException) {
      // 本机实测 api.github.com 被解析到 127.0.0.1，就是这个症状
      return '连不上 $apiBase（DNS 或网络被拦）';
    }
    if (e is TimeoutException) return '连接超时';
    if (e is HandshakeException) return '证书校验失败';
    if (e is FormatException) return '返回内容不是合法 JSON';
    return s.length > 120 ? '${s.substring(0, 120)}…' : s;
  }

  /// 下载 APK，带进度回调。
  ///
  /// 依次尝试「镜像 → 直连」，第一个成功的返回。
  /// 每个源先写 `.part`，成功且大小校验通过才改名 ——
  /// 避免半截文件被当成「已下载」。
  Future<File?> download({
    required UpdateInfo info,
    required Directory cacheDir,
    void Function(int percent, String source)? onProgress,
  }) async {
    if (info.downloadUrl.isEmpty) return null;

    final dir = Directory('${cacheDir.path}/updates');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final out = File('${dir.path}/dsh-flutter-${info.latestVersion}.apk');

    // 已经下过且大小对得上：直接用
    if (out.existsSync() && info.sizeBytes > 0 && out.lengthSync() == info.sizeBytes) {
      onProgress?.call(100, '缓存');
      return out;
    }

    final candidates = downloadCandidates(info.downloadUrl);
    for (final url in candidates) {
      final sourceName = Uri.tryParse(url)?.host ?? '镜像';
      final part = File('${dir.path}/dsh-flutter-${info.latestVersion}.part');
      try {
        if (part.existsSync()) part.deleteSync();
      } catch (_) {}

      HttpClient? c;
      try {
        c = _client(connect: const Duration(seconds: 12));
        final req = await c.getUrl(Uri.parse(url));
        if (url.contains('/releases/assets/')) {
          req.headers.set('Accept', 'application/octet-stream');
        }
        final res = await req.close();
        if (res.statusCode != 200) {
          c.close(force: true);
          continue; // 换下一个源
        }

        final total = res.contentLength;
        final sink = part.openWrite();
        var done = 0;
        var lastPct = -1;

        await for (final chunk in res) {
          sink.add(chunk);
          done += chunk.length;
          if (total > 0) {
            final pct = (done * 100 / total).toInt();
            if (pct != lastPct) {
              lastPct = pct;
              onProgress?.call(pct, sourceName);
            }
          }
        }
        await sink.flush();
        await sink.close();

        /*
         * 校验完整性再改名。
         *
         * 镜像偶尔返回「200 但内容不对」（错误页、被截断的流）。
         * 不校验就改名的话，下次 `length == sizeBytes` 的短路
         * 会把这个坏包当成好的 —— 表现为「下载成功但装不上」。
         */
        final got = part.lengthSync();
        final sizeOk = info.sizeBytes <= 0 || got == info.sizeBytes;
        if (!sizeOk) {
          try { part.deleteSync(); } catch (_) {}
          continue;
        }
        if (out.existsSync()) {
          try { out.deleteSync(); } catch (_) {}
        }
        part.renameSync(out.path);
        onProgress?.call(100, sourceName);
        return out;
      } catch (_) {
        try { if (part.existsSync()) part.deleteSync(); } catch (_) {}
        // 网络中断 / 超时：换下一个源
      } finally {
        c?.close(force: true);
      }
    }
    return null; // 所有源都失败
  }
}


