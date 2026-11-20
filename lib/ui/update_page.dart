/// DSH 工作台 —— 应用内更新页（阶段⑥）。
///
/// 流程：查最新 release → 有新版就下载（带进度、多镜像兜底）→ 拉起系统安装器。
///
/// ⚠️ 三条必须知道的（都来自 Kotlin 版真机实测）：
///
///  1. **Android 不允许 App 静默安装自己**。下载完只能拉起系统安装器，
///     由用户点「安装」。任何声称能绕过的做法都要利用系统漏洞。
///  2. **没授权「安装未知应用」时，安装器会被秒杀**，界面无任何反应。
///     所以点安装前必须先查权限，没开就引导用户去开。
///  3. **`api.github.com` 在国内常常完全不可达**（本机 DNS 返回 127.0.0.1）。
///     所以查询失败时要给出人话提示，并允许改 API 端点。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../data/installer.dart';
import '../data/update_api.dart';
import 'icons.dart';
import 'theme_toggle.dart';
import 'theme.dart';

class UpdatePage extends StatefulWidget {
  final bool dark;

  /// 仓库名（`owner/repo`）。空串用默认。
  final String repo;

  /// API 端点，可在设置里改（国内默认的 api.github.com 常常不通）。
  final String apiBase;

  /// 保存新配置的回调。返回后页面会用新值重建 api。
  final Future<void> Function(String repo, String apiBase)? onSaveConfig;

  const UpdatePage({
    super.key,
    required this.dark,
    this.repo = UpdateApi.defaultRepo,
    this.apiBase = 'https://api.github.com',
    this.onSaveConfig,
  });

  @override
  State<UpdatePage> createState() => _UpdatePageState();
}

class _UpdatePageState extends State<UpdatePage> {
  String _current = '';
  UpdateInfo? _info;
  bool _checking = false;

  bool _downloading = false;
  int _percent = 0;
  String _source = '';

  String? _installedPath;
  String? _message;
  bool _isError = false;

  late UpdateApi _api;

  /// 可编辑的配置（默认取 widget 传进来的值）。
  late final TextEditingController _repoCtrl;
  late final TextEditingController _apiCtrl;
  bool _showConfig = false;

  @override
  void initState() {
    super.initState();
    _repoCtrl = TextEditingController(text: widget.repo);
    _apiCtrl = TextEditingController(text: widget.apiBase);
    _rebuildApi();
    _loadVersion();
  }

  @override
  void dispose() {
    _repoCtrl.dispose();
    _apiCtrl.dispose();
    super.dispose();
  }

  /// 用**当前输入框里的值**重建 api。
  ///
  /// ⚠️ 不能读 `widget.repo` / `widget.apiBase` —— 那是 initState 时传进来的
  /// 初始值，用户改了输入框它们不会变。早先写成读 widget 的，结果：
  /// 配置区显示新仓库，但「检查更新」还在查旧仓库，报
  /// 「仓库 某个旧账号/旧仓库 不存在」—— 用户看到的是「保存没生效」。
  void _rebuildApi() {
    final repo = _repoCtrl.text.trim();
    final api = _apiCtrl.text.trim();
    _api = UpdateApi(
      apiBase: api.isEmpty ? 'https://api.github.com' : api,
      repo: repo.isEmpty ? UpdateApi.defaultRepo : repo,
    );
  }

  /// 保存仓库/API 配置。
  ///
  /// 为什么让用户能改：GitHub 账号可能被停用（已经发生过一次，
  /// 仓库直接 404），或者想用自己的 fork、或者 api.github.com 不可达
  /// 要换反代。写死在源码里意味着「更新通道坏了就只能改代码重发版」——
  /// 而更新通道本身坏了就发不了版，死锁。
  Future<void> _saveConfig() async {
    final repo = _repoCtrl.text.trim();
    final api = _apiCtrl.text.trim();
    if (repo.isEmpty || !repo.contains('/')) {
      _say('仓库要写成 owner/repo 形式', error: true);
      return;
    }
    if (!api.startsWith('http')) {
      _say('API 源要以 http:// 或 https:// 开头', error: true);
      return;
    }
    await widget.onSaveConfig?.call(repo, api);
    _rebuildApi();
    if (!mounted) return;
    setState(() {
      _info = null;
      _installedPath = null;
      _message = null;
    });
    _say('配置已保存，点「检查更新」重试');
  }

  Future<void> _loadVersion() async {
    try {
      final pi = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() => _current = pi.version);
    } catch (_) {
      if (!mounted) return;
      setState(() => _current = '未知');
    }
  }

  void _say(String msg, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _message = msg;
      _isError = error;
    });
  }

  /* ---------------- 检查 ---------------- */

  Future<void> _check() async {
    if (_checking) return;
    setState(() {
      _checking = true;
      _message = null;
      _installedPath = null;
    });
    final info = await _api.check(_current.isEmpty ? '0' : _current);
    if (!mounted) return;
    setState(() {
      _checking = false;
      _info = info;
    });
    if (!info.ok) {
      _say(info.error!, error: true);
    } else if (!info.hasUpdate) {
      _say('已是最新版本');
    }
  }

  /* ---------------- 下载 ---------------- */

  Future<void> _download() async {
    final info = _info;
    if (info == null || !info.hasUpdate || _downloading) return;

    setState(() {
      _downloading = true;
      _percent = 0;
      _source = '';
      _message = null;
      _installedPath = null;
    });

    /*
     * ⚠️ 下载目录必须和 FileProvider 的映射**严格对应**。
     *
     * 踩过两次：
     *
     *  1. 用 `Directory.systemTemp` —— 它在 Android 上映射到 **code_cache**，
     *     不是 cache。而 FileProvider 配的是 `cache-path`（对应 cacheDir），
     *     两者对不上，拉起安装器时报：
     *
     *       IllegalArgumentException: Failed to find configured root
     *       that contains /data/data/<pkg>/code_cache/updates/xxx.apk
     *
     *     表现是「下载成功，点安装瞬间失败」。
     *
     *  2. 而 `cache-path` 这个 XML 元素**只能**映射 `<cacheDir>`，
     *     没法映射 code_cache（要映射得用 root-path，那就等于放开整块磁盘）。
     *
     * 所以正确做法是从源头把目录钉死在 cacheDir：
     * 用 MethodChannel 问原生要 `getCacheDir()`，保证和 file_paths.xml 一致。
     */
    final cachePath = await Installer.cacheDirPath();
    if (!mounted) return;
    if (cachePath == null) {
      setState(() => _downloading = false);
      _say('拿不到缓存目录，无法下载', error: true);
      return;
    }
    final cacheDir = Directory(cachePath);

    final file = await _api.download(
      info: info,
      cacheDir: cacheDir,
      onProgress: (pct, src) {
        if (!mounted) return;
        setState(() {
          _percent = pct;
          _source = src;
        });
      },
    );

    if (!mounted) return;
    setState(() => _downloading = false);

    if (file == null) {
      _say('下载失败：所有镜像和直连都试过了', error: true);
      return;
    }
    setState(() => _installedPath = file.path);
    _say('下载完成（${_fmt(info.sizeBytes)}）');
  }

  /* ---------------- 安装 ---------------- */

  Future<void> _install() async {
    final path = _installedPath;
    if (path == null) return;

    final ok = await Installer.canInstall();
    if (!mounted) return;
    if (!ok) {
      /*
       * 没权限时不能直接调 installApk —— 系统安装器会启动后秒杀，
       * 用户看到的是「点了没反应」。必须先把人引到授权页。
       */
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) {
          final c = DshColors.of(widget.dark);
          return AlertDialog(
            backgroundColor: c.sheetFill,
            title: Text('需要授权', style: TextStyle(color: c.textPrimary)),
            content: Text(
              '安装新版本需要「安装未知应用」权限。\n'
              '下面会打开系统设置，找到本应用并打开开关，然后回来再点安装。',
              style: TextStyle(color: c.textSecondary, fontSize: 13, height: 1.5),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
              TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('去授权')),
            ],
          );
        },
      );
      if (go == true) {
        await Installer.openInstallSettings();
        if (mounted) _say('授权后回来再点「安装」');
      }
      return;
    }

    final err = await Installer.installApk(path);
    if (!mounted) return;
    if (err != null) {
      _say('拉起安装器失败：$err', error: true);
    } else {
      _say('已打开系统安装器，请在系统界面点「安装」');
    }
  }

  static String _fmt(int n) {
    if (n <= 0) return '大小未知';
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  /// 精简 Release body：去掉下载区块（界面上已有「下载」按钮）和末尾的源码链接。
  ///
  /// 为什么要在客户端裁剪：Release body 是给人看的完整说明，
  /// 但 App 里空间有限，而且「下载」这件事已经由按钮承担了 ——
  /// 再把两条 raw 链接和「本包含 xx 架构」之类的废话铺一遍纯属噪音。
  ///
  /// 实现用**按行扫描**而不是单个正则：
  /// 正则 `#{1,4}(下载)[\s\S]*?(?=\n#{1,4})` 看着对，
  /// 但 `[\s\S]*?` 在跨行前瞻上的行为很难调 —— 实测它会一路吃到底。
  /// 按行判断「遇到同级/更高级标题就停」既直观又不会误伤正文。
  static String _trimNotes(String raw) {
    final lines = raw.split('\n');
    final out = <String>[];
    // 当前是否处在要丢弃的区块里
    var skip = false;
    var skipLevel = 0;

    bool isHeading(String t) => RegExp(r'^#{1,6}\s').hasMatch(t);

    int headingLevel(String t) {
      final m = RegExp(r'^(#{1,6})\s').firstMatch(t);
      return m == null ? 0 : m.group(1)!.length;
    }

    bool isNoiseHeading(String t) =>
        RegExp(r'^#{1,6}\s*(下载|Download|源码|Source)(\s|$)', caseSensitive: false)
            .hasMatch(t);

    for (final line in lines) {
      final t = line.trim();

      if (isHeading(t)) {
        if (skip) {
          // 遇到同级或更高级标题 → 区块结束
          if (headingLevel(t) <= skipLevel) skip = false;
        }
        if (!skip && isNoiseHeading(t)) {
          skip = true;
          skipLevel = headingLevel(t);
          continue;
        }
        if (skip) continue;
        out.add(line);
        continue;
      }

      if (skip) continue;

      // 裸的 GitHub 链接行去掉
      if (t.isNotEmpty &&
          (t.contains('github.com/') || t.contains('gh-proxy.com/'))) {
        continue;
      }
      out.add(line);
    }

    var s = out.join('\n');
    s = s.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return s.trim();
  }

  /// Markdown 样式：压到 11.5px 正文，标题不抢戏。
  static MarkdownStyleSheet _mdStyle(DshColors c) {
    final base = TextStyle(fontSize: 11.5, height: 1.5, color: c.textSecondary);
    return MarkdownStyleSheet(
      p: base,
      h1: base.copyWith(fontSize: 14, fontWeight: FontWeight.bold, color: c.textPrimary),
      h2: base.copyWith(fontSize: 13, fontWeight: FontWeight.bold, color: c.textPrimary),
      h3: base.copyWith(fontSize: 12, fontWeight: FontWeight.bold, color: c.textPrimary),
      listBullet: base,
      strong: base.copyWith(fontWeight: FontWeight.bold, color: c.textPrimary),
      em: base.copyWith(fontStyle: FontStyle.italic),
      code: TextStyle(
        fontSize: 10.5,
        fontFamily: 'monospace',
        // ⚠️ 不要用 accent 色。accent 是链接色，行内代码染成那个颜色后
        // 看起来和可点链接一模一样，用户会去点（实测反馈过）。
        // 用主文字色 + 略深的底，靠形态区分而不是靠颜色。
        color: c.textPrimary,
        backgroundColor: c.stroke,
      ),
      codeblockDecoration: BoxDecoration(
        color: c.winBg.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(4),
      ),
      a: base.copyWith(color: c.accent),
      blockSpacing: 6,
      listIndent: 14,
    );
  }

  /* ---------------- 渲染 ---------------- */

  @override
  Widget build(BuildContext context) {
    final c = DshColors.of(widget.dark);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SizedBox.expand(
        child: MicaBackdrop(
          dark: widget.dark,
          child: SafeArea(
            child: Column(
              children: [
                _bar(c),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                    children: [
                      _versionCard(c),
                      const SizedBox(height: 12),
                      if (_info != null && _info!.ok && _info!.hasUpdate)
                        _updateCard(c),
                      if (_downloading) _progressCard(c),
                      if (_installedPath != null) _installCard(c),
                      if (_message != null) _messageCard(c),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _bar(DshColors c) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 6, 12, 6),
      child: Row(
        children: [
          IconButton(
            icon: DshIcon(DshGlyph.back, size: 20, color: c.textPrimary),
            constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
            padding: const EdgeInsets.all(8),
            onPressed: () => Navigator.of(context).pop(),
          ),
          const SizedBox(width: 2),
          const Spacer(),
          // 每个页面都能切主题
          ThemeToggleButton(color: c.textPrimary),
          Text(
            '应用内更新',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: c.textPrimary,
            ),
          ),
        ],
      ),
    );
  }

  /// 自检：验证原生 MethodChannel 是否打通。
  ///
  /// 这个按钮放在配置区里，作用是**让「原生通道坏了」这件事可见**。
  /// 通道没注册（比如改了 Kotlin 但没重编、或 authority 对不上）时，
  /// 安装会静默失败 —— 用户只看到「点了没反应」。
  Future<void> _selfTest() async {
    final can = await Installer.canInstall();
    if (!mounted) return;
    _say(
      can
          ? '原生通道正常 · 已获「安装未知应用」权限'
          : '原生通道正常 · 尚未获得「安装未知应用」权限（点安装会引导去开）',
    );
  }

  Widget _versionCard(DshColors c) {
    return FluentCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              DshIcon(DshGlyph.sync, size: 20, color: c.accent),
              const SizedBox(width: 8),
              Text(
                '当前版本',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: c.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            _current.isEmpty ? '读取中…' : 'v$_current',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: c.textPrimary),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _checking ? null : _check,
              style: FilledButton.styleFrom(
                backgroundColor: c.accent,
                foregroundColor: c.onAccent,
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: _checking
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: c.onAccent),
                    )
                  : const Text('检查更新'),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '仓库 ${_api.repo} · 源 ${_api.apiBase}',
            style: TextStyle(fontSize: 10.5, color: c.textTertiary),
          ),
          const SizedBox(height: 6),
          TextButton(
            onPressed: () => setState(() => _showConfig = !_showConfig),
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              minimumSize: const Size(0, 28),
              alignment: Alignment.centerLeft,
            ),
            child: Text(
              _showConfig ? '收起配置' : '更新通道不通？点这里改仓库 / API 源',
              style: TextStyle(fontSize: 11, color: c.accent),
            ),
          ),
          if (_showConfig) ...[
            const SizedBox(height: 6),
            TextField(
              controller: _repoCtrl,
              style: TextStyle(fontSize: 12.5, color: c.textPrimary),
              decoration: InputDecoration(
                labelText: '仓库（owner/repo）',
                labelStyle: TextStyle(fontSize: 12, color: c.textTertiary),
                hintText: 'owner/repo',
                isDense: true,
                filled: true,
                fillColor: c.inputFill,
                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: c.stroke),
                ),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _apiCtrl,
              style: TextStyle(fontSize: 12.5, color: c.textPrimary),
              decoration: InputDecoration(
                labelText: 'API 源',
                labelStyle: TextStyle(fontSize: 12, color: c.textTertiary),
                hintText: 'https://api.github.com',
                isDense: true,
                filled: true,
                fillColor: c.inputFill,
                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: c.stroke),
                ),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: _saveConfig,
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: c.accent, width: 1),
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: Text('保存配置', style: TextStyle(fontSize: 12.5, color: c.accent)),
              ),
            ),
            const SizedBox(height: 6),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: _selfTest,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 9),
                ),
                child: Text(
                  '检测安装通道',
                  style: TextStyle(fontSize: 12, color: c.textSecondary),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _updateCard(DshColors c) {
    final info = _info!;
    return FluentCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              DshIcon(DshGlyph.star, size: 18, color: c.success),
              const SizedBox(width: 8),
              Text(
                '发现新版本 v${info.latestVersion}',
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.bold,
                  color: c.textPrimary,
                ),
              ),
            ],
          ),
          if (info.sizeBytes > 0) ...[
            const SizedBox(height: 4),
            Text(_fmt(info.sizeBytes), style: TextStyle(fontSize: 11.5, color: c.textTertiary)),
          ],
          if (info.releaseNotes.trim().isNotEmpty) ...[
            const SizedBox(height: 10),
            /*
             * 更新说明要**渲染成 Markdown**，不能直接当纯文本显示。
             *
             * 踩过：原来直接用 Text() 显示，Release body 里的
             * `## 标题`、`- [链接](url)` 全部原样露出来，
             * 用户看到一堆 `##` 和裸 URL。
             *
             * 另外 Release body 可能很长（整个 CHANGELOG），
             * 所以限高 + 可滚动，不把卡片撑爆。
             */
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 220),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: c.inputFill,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: c.stroke),
              ),
              child: SingleChildScrollView(
                child: MarkdownBody(
                  data: _trimNotes(info.releaseNotes),
                  styleSheet: _mdStyle(c),
                  onTapLink: (text, href, title) {
                    // 链接点了没反应会让人困惑，至少给个提示
                    if (href != null) {
                      Clipboard.setData(ClipboardData(text: href));
                      _say('链接已复制：$href');
                    }
                  },
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: (_downloading || _installedPath != null) ? null : _download,
              style: FilledButton.styleFrom(
                backgroundColor: c.accent,
                foregroundColor: c.onAccent,
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: const Text('下载'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _progressCard(DshColors c) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: FluentCard(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _source.isEmpty ? '连接中…' : '正在从 $_source 下载',
                    style: TextStyle(fontSize: 12, color: c.textSecondary),
                  ),
                ),
                Text(
                  '$_percent%',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: c.accent,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: _percent / 100,
                minHeight: 7,
                backgroundColor: c.stroke,
                valueColor: AlwaysStoppedAnimation(c.accent),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _installCard(DshColors c) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: FluentCard(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'APK 已下载',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: c.textPrimary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Android 不允许 App 自动安装自己，需要你在系统界面点「安装」。',
              style: TextStyle(fontSize: 11.5, height: 1.45, color: c.textTertiary),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _install,
                icon: DshIcon(DshGlyph.fileApk, size: 18, color: c.onAccent),
                label: const Text('安装'),
                style: FilledButton.styleFrom(
                  backgroundColor: c.accent,
                  foregroundColor: c.onAccent,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _messageCard(DshColors c) {
    final color = _isError ? c.danger : c.success;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DshIcon(_isError ? DshGlyph.info : DshGlyph.check, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _message!,
              style: TextStyle(fontSize: 12, height: 1.45, color: color),
            ),
          ),
        ],
      ),
    );
  }
}




