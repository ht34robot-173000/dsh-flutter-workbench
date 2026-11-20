/// DSH 工作台（Flutter 版）—— 应用外壳与状态。
///
/// 迁移策略：从 Kotlin 版 v4.7 逐步搬，每一步都要能在模拟器上真的用起来
/// 才往下走。当前进度见 [MigrationStage]。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'data/ds_api.dart';
import 'data/fs_api.dart';
import 'data/scan_parse.dart';
import 'data/live.dart';
import 'data/prefs.dart';
import 'ui/chat_page.dart';
import 'ui/file_browser_page.dart';
import 'ui/profile_page.dart';
import 'ui/scan_page.dart';
import 'ui/update_page.dart';
import 'ui/icons.dart';
import 'data/session_data.dart';
import 'data/session_store.dart';
import 'data/system_api.dart';
import 'ui/session_list_page.dart';
import 'ui/theme.dart';
import 'ui/theme_reveal.dart';
import 'ui/workbench_shell.dart';

/// 迁移进度 —— 打印在「我的」页上，随时能看出这个版本到哪一步了。
enum MigrationStage {
  connection('① 连接与配对'),
  sessions('② 会话列表'),
  chat('③ 对话与实时流'),
  files('④ 文件管理'),
  scan('⑤ 扫码配对'),
  updater('⑥ 应用内更新');

  final String label;
  const MigrationStage(this.label);
}

/// 当前已经完成的阶段（真实可用才算）。每做完一步就往上加。
const MigrationStage kCurrentStage = MigrationStage.updater;

class AppState extends ChangeNotifier {
  late Prefs prefs;
  late DshApi api;
  late FsApi fsApi;
  bool dark = false;

  /// 正在播放主题揭示动画时的目标明暗。null = 没有动画。
  bool? revealToDark;
  Offset? revealOrigin;

  bool ready = false;

  /// 最近一次连接检查结果。
  String? connHint;
  bool? connOk;

  Future<void> boot() async {
    prefs = await Prefs.load();
    api = DshApi(prefs);
    fsApi = FsApi(prefs);
    dark = prefs.isDark;
    ready = true;
    notifyListeners();
    await checkConnection();
  }

  Future<void> checkConnection() async {
    if (prefs.baseUrl.isEmpty) {
      connOk = false;
      connHint = '还没填服务器地址';
      notifyListeners();
      return;
    }
    if (!api.hasCookie) {
      connOk = false;
      connHint = '还没配对';
      notifyListeners();
      return;
    }
    final r = await api.state();
    connOk = r.ok;
    connHint = r.ok ? null : r.friendlyError;
    notifyListeners();
  }

  /// 切换主题。
  ///
  /// ⚠️ 这里刻意**不接受「system」档**，切换永远按「当前实际明暗」取反。
  /// Kotlin 版在这踩过让用户反复报「白天有概率切不了」的坑：
  /// 三档轮换 system→light→dark 里，白天（系统浅色）时
  /// 「system(浅)→light(浅)」界面毫无变化，用户以为按钮坏了。
  void toggleTheme({Offset? origin}) {
    revealToDark = !dark;
    revealOrigin = origin;
    notifyListeners();
  }

  /// 主题揭示动画要的「抓帧已完成」信号 —— **此时才真正换主题**。
  ///
  /// 顺序很关键：先抓帧（旧外观）→ 再换主题 → 快照盖在上面挖洞揭示。
  /// 反过来做，抓到的就是新外观，动画会变成「新的盖新的」，什么都看不见。
  ///
  /// 注意这里**不清 `revealOrigin`**：动画还在用那个圆心，
  /// 中途清掉会让圆形从屏幕中心重新开始。
  Future<void> commitTheme() async {
    final target = revealToDark;
    if (target == null) return;
    dark = target;
    revealToDark = null;
    await prefs.setDark(dark);
    notifyListeners();
  }

  /// 动画播完（快照已释放）。只回收圆心，不再动主题。
  void finishReveal() {
    if (revealOrigin == null && revealToDark == null) return;
    revealOrigin = null;
    revealToDark = null;
    notifyListeners();
  }

  Future<void> saveConnection({
    required NetMode mode,
    required String lanUrl,
    required String wanUrl,
  }) async {
    await prefs.setLanUrl(lanUrl);
    await prefs.setWanUrl(wanUrl);
    await prefs.setMode(mode);
    api.reload();
    // 文件接口是独立实例，地址变了它也要跟着切
    fsApi.reload();
    // 缓存里的列表属于**上一台服务器**，必须扔掉，否则会显示别人的会话
    SessionStore.instance.reset();
    notifyListeners();
    await checkConnection();
  }

  /// 用 6 位码配对（沿用当前已保存的地址）。
  Future<ApiResult> pair(String code) async {
    final r = await api.acceptPair(code);
    if (r.ok) {
      // 换了设备凭据 → 能看到的会话可能不同，缓存作废
      SessionStore.instance.reset();
      await checkConnection();
    }
    return r;
  }

  /// 用扫码结果配对：**地址和码一起换**。
  ///
  /// ⚠️ 不能只换 code。二维码里带着 baseUrl，如果只取 code
  /// 而地址还留着上一次的，就会「配对成功但连的是另一台机器」——
  /// 界面上看不出任何异常，只是数据不对。
  Future<ApiResult> pairFromScan(PairScanResult scan) async {
    if (scan.baseUrl.isNotEmpty && scan.baseUrl != prefs.baseUrl) {
      // 地址变了：先落盘再 reload，否则 acceptPair 还打到旧地址
      if (prefs.mode == NetMode.wan) {
        await prefs.setWanUrl(scan.baseUrl);
      } else {
        await prefs.setLanUrl(scan.baseUrl);
      }
      api.reload();
      fsApi.reload();
      SessionStore.instance.reset();
      notifyListeners();
    }
    final r = await api.acceptPair(scan.code);
    if (r.ok) {
      SessionStore.instance.reset();
      await checkConnection();
    }
    return r;
  }
}

/// 让子组件随处拿到 [AppState]，不必层层透传。
class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child})
      : super(notifier: state);

  static AppState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;
}

void main() {
  runApp(const DshWorkbenchApp());
}

class DshWorkbenchApp extends StatefulWidget {
  const DshWorkbenchApp({super.key});

  @override
  State<DshWorkbenchApp> createState() => _DshWorkbenchAppState();
}

class _DshWorkbenchAppState extends State<DshWorkbenchApp> {
  final _state = AppState();

  @override
  void initState() {
    super.initState();
    _state.boot();
  }

  @override
  void dispose() {
    _state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: _state,
      child: ListenableBuilder(
        listenable: _state,
        builder: (context, _) {
          if (!_state.ready) {
            return MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: DshColors.of(false).toThemeData(),
              home: const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              ),
            );
          }

          final colors = DshColors.of(_state.dark);
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            title: 'DSH 工作台',
            theme: colors.toThemeData(),
            home: ThemeRevealScope(
              active: _state.revealToDark != null,
              toDark: _state.revealToDark ?? false,
              origin: _state.revealOrigin,
              // 抓帧完成才换主题；动画播完只回收圆心
              onCaptured: _state.commitTheme,
              onCompleted: _state.finishReveal,
              child: const HomePage(),
            ),
          );
        },
      ),
    );
  }
}

/// 首页：会话列表（阶段②）。
///
/// Kotlin 版的首页就是「按工作区分组的会话列表」，标题栏 + 底部两格。
/// 这里保持一致：body 直接是 SessionListPage，外壳用 WorkbenchShell。
///
/// 「我的」页在阶段②还是占位 —— 它要等 ProfileView 迁过来。
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _tab = 0;

  /// SSE 长连接：全 App 共用一个。
  ///
  /// 为什么不在对话页里各自建：宿主那边每条连接都是一个长响应，
  /// 来回进出会话会积一堆。共享一条、按 sessionId 分拣最省。
  LiveClient? _live;

  LiveClient _ensureLive(AppState state) {
    return _live ??= LiveClient(state.prefs);
  }

  @override
  void dispose() {
    _live?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;

    // 没配对成功之前不给列表 —— 列表页会一直报「设备未配对」，
    // 不如直接说清楚该做什么。
    final ready = state.api.hasCookie && state.prefs.baseUrl.isNotEmpty;

    return WorkbenchShell(
      dark: dark,
      currentTab: _tab,
      onTab: (i) => setState(() => _tab = i),
      drawer: _buildDrawer(context, state, dark),
      onToggleTheme: (origin) => state.toggleTheme(origin: origin),
      onSettings: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const SettingsPage()),
      ),
      /*
       * ⚠️ 用 IndexedStack 而不是 `_tab == 0 ? a : b` 三元。
       *
       * 三元写法每次切页签都会**销毁并重建**另一个页面 —— 会话列表要重新请求、
       * 转一次圈、滚动位置回到顶部。IndexedStack 把两页都留在树上（只是不显示），
       * 切回来是瞬时的。
       *
       * 代价：两页都会建一次。这里无所谓 —— 「我的」页是纯静态的，
       * 会话列表的数据本来就要拉。
       */
      body: IndexedStack(
        index: _tab,
        sizing: StackFit.expand,
        children: [
          ready
              ? SessionListPage(
                  api: state.api,
                  dark: dark,
                  onOpenSession: (s) => _openChat(context, state, s, dark),
                )
              : _NotReady(dark: dark),
          ProfilePage(api: state.api, dark: dark),
        ],
      ),
    );
  }

  void _openChat(
    BuildContext context,
    AppState state,
    SessionItem s,
    bool dark,
  ) {
    unawaited(_pushChat(context, state, s, dark));
  }

  /// 进对话页，**回来后静默刷新一次列表**。
  ///
  /// 为什么要刷新：刚聊过的会话标题 / 时间 / running 状态都变了，
  /// 不刷新列表就是旧的。但这次刷新是**静默**的（store 里有数据时不显示转圈），
  /// 也不会打断滚动位置 —— 用户感觉不到，数据却是新的。
  Future<void> _pushChat(
    BuildContext context,
    AppState state,
    SessionItem s,
    bool dark,
  ) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatPage(
          api: state.api,
          fs: state.fsApi,
          live: _ensureLive(state),
          sessionId: s.id,
          title: s.title,
          dark: dark,
        ),
      ),
    );
    // 回来了：后台把列表对一次账（静默，不显示加载）
    unawaited(SessionStore.instance.load(state.api, force: true));
  }

  /// 左侧抽屉的内容。
  ///
  /// 和改之前的区别：原来是 `showModalBottomSheet`（底部弹层），
  /// 点左上角 ☰ 却从屏幕底下弹出来 —— 语义和所有 Android App 的习惯相反。
  /// 现在交给 `Scaffold.drawer`，从左滑出、可左划关闭、跟手。
  Widget _buildDrawer(BuildContext context, AppState state, bool dark) {
    return _HomeDrawer(
      api: state.api,
      fs: state.fsApi,
      prefs: state.prefs,
      dark: dark,
      onOpenFiles: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => FileBrowserPage(fs: state.fsApi, dark: dark),
        ),
      ),
      onOpenUpdate: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => UpdatePage(
            dark: dark,
            repo: state.prefs.updateRepo,
            apiBase: state.prefs.updateApi,
            onSaveConfig: (repo, api) async {
              await state.prefs.setUpdateRepo(repo);
              await state.prefs.setUpdateApi(api);
            },
          ),
        ),
      ),
      onRestarted: () {
        // 重启后宿主会断一轮：清掉缓存，等十几秒再探一次连接
        SessionStore.instance.reset();
        Future<void>.delayed(const Duration(seconds: 12), state.checkConnection);
      },
    );
  }
}

/// 左侧抽屉：导航 + 远程重启。
class _HomeDrawer extends StatefulWidget {
  final DshApi api;
  final FsApi fs;
  final Prefs prefs;
  final bool dark;
  final VoidCallback onOpenFiles;
  final VoidCallback onOpenUpdate;
  final VoidCallback onRestarted;

  const _HomeDrawer({
    required this.api,
    required this.fs,
    required this.prefs,
    required this.dark,
    required this.onOpenFiles,
    required this.onOpenUpdate,
    required this.onRestarted,
  });

  @override
  State<_HomeDrawer> createState() => _HomeDrawerState();
}

class _HomeDrawerState extends State<_HomeDrawer> {
  late final SystemApi _sys = SystemApi(widget.api);
  RestartStatus? _status;
  bool _restarting = false;

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  Future<void> _loadStatus() async {
    final (_, s) = await _sys.restartStatus();
    if (!mounted) return;
    setState(() => _status = s);
  }

  void _close() => Navigator.of(context).maybePop();

  String _uptime() {
    final ms = _status?.hostUptimeMs;
    if (ms == null) return '';
    final d = Duration(milliseconds: ms);
    if (d.inHours >= 1) return '已运行 ${d.inHours} 小时 ${d.inMinutes % 60} 分';
    if (d.inMinutes >= 1) return '已运行 ${d.inMinutes} 分钟';
    return '刚启动';
  }

  Future<void> _confirmRestart() async {
    final c = DshColors.of(widget.dark);
    final ok = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black38,
      builder: (ctx) => Dialog(
        backgroundColor: c.sheetFill,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '重启 DSH？',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: c.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '会用 dsh-seamless-restart 的 relaunch.ps1 彻底重启桌面端。'
                '那 5-15 秒桌面会显示磨砂遮罩，手机这边要等十几秒才能重连。',
                style: TextStyle(fontSize: 12.5, height: 1.4, color: c.textSecondary),
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: Text('取消', style: TextStyle(color: c.textSecondary)),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    style: FilledButton.styleFrom(
                      backgroundColor: c.accent,
                      foregroundColor: c.onAccent,
                    ),
                    child: const Text('重启'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _restarting = true);
    final r = await _sys.restart();
    if (!mounted) return;
    setState(() => _restarting = false);

    if (!r.ok) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text('重启失败：${r.friendlyError}')));
      return;
    }
    _close();
    widget.onRestarted();
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(const SnackBar(
        content: Text('已请求重启，约 10-20 秒后自动重连'),
        duration: Duration(seconds: 4),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final c = DshColors.of(widget.dark);
    final canRestart = _status?.canRestart ?? false;

    return Drawer(
      backgroundColor: c.sheetFill,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 品牌头
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 10),
              child: Row(
                children: [
                  DshIcon(DshGlyph.chat, size: 20, color: c.accent),
                  const SizedBox(width: 8),
                  Text(
                    'DSH 工作台',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: c.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
            Divider(color: c.stroke, height: 1),
            _item(
              c,
              glyph: DshGlyph.folder,
              title: '文件管理',
              subtitle: '浏览、预览、上传、下载宿主文件',
              onTap: () {
                _close();
                widget.onOpenFiles();
              },
            ),
            _item(
              c,
              glyph: DshGlyph.sync,
              title: '检查更新',
              subtitle: '从 GitHub Releases 拉新版本',
              onTap: () {
                _close();
                widget.onOpenUpdate();
              },
            ),
            Divider(color: c.stroke, height: 1),
            _item(
              c,
              glyph: DshGlyph.bolt,
              title: _restarting ? '正在重启…' : '重启 DSH',
              subtitle: _status == null
                  ? '正在读取重启状态…'
                  : (canRestart
                      ? '远程重启桌面端 · ${_uptime()}'
                      : _status!.reasonText),
              onTap: canRestart && !_restarting ? _confirmRestart : null,
              trailing: _restarting
                  ? SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 1.6, color: c.accent),
                    )
                  : null,
            ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.prefs.baseUrl.isEmpty ? '未配置地址' : widget.prefs.baseUrl,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10.5, color: c.textTertiary),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '长按消息可选中复制 · 路径可点开资源管理器',
                    style: TextStyle(fontSize: 10, color: c.textTertiary),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _item(
    DshColors c, {
    required DshGlyph glyph,
    required String title,
    required String subtitle,
    VoidCallback? onTap,
    Widget? trailing,
  }) {
    final enabled = onTap != null;
    final fg = enabled ? c.textPrimary : c.textTertiary;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 14, 12),
          child: Row(
            children: [
              DshIcon(glyph, size: 19, color: fg),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title, style: TextStyle(fontSize: 13.5, color: fg)),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: c.textTertiary),
                    ),
                  ],
                ),
              ),
              if (trailing != null) trailing,
            ],
          ),
        ),
      ),
    );
  }
}
/// 还没配对时的引导页。
class _NotReady extends StatelessWidget {
  final bool dark;
  const _NotReady({required this.dark});

  @override
  Widget build(BuildContext context) {
    final c = DshColors.of(dark);
    final state = AppScope.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DshIcon(DshGlyph.link, size: 40, color: c.textTertiary),
            const SizedBox(height: 14),
            Text(
              state.prefs.baseUrl.isEmpty ? '还没配置服务器地址' : '还没配对设备',
              style: TextStyle(fontSize: 14, color: c.textPrimary),
            ),
            const SizedBox(height: 6),
            Text(
              '去「连接设置」填地址并在电脑端点“配对我的手机”取 6 位配对码',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: c.textTertiary),
            ),
            const SizedBox(height: 18),
            FilledButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsPage()),
              ),
              child: const Text('去配置'),
            ),
          ],
        ),
      ),
    );
  }
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _lan;
  late final TextEditingController _wan;
  late final TextEditingController _code;
  NetMode _mode = NetMode.lan;
  bool _busy = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    final s = AppScope.of(context);
    _lan = TextEditingController(text: s.prefs.lanUrl);
    _wan = TextEditingController(text: s.prefs.wanUrl);
    _code = TextEditingController();
    _mode = s.prefs.mode;
  }

  @override
  void dispose() {
    _lan.dispose();
    _wan.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final s = AppScope.of(context);
    setState(() => _busy = true);
    await s.saveConnection(
      mode: _mode,
      lanUrl: _lan.text,
      wanUrl: _wan.text,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    // 用 SnackBar 而不是在卡片里加一行字：
    // 卡片里的提示在长页面上可能滚出视野，用户点了「保存」看不到任何反馈
    // （阶段①实测踩到过：文字在屏幕外，看起来像没保存成功）。
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(s.connOk == true ? '已保存，连接正常' : (s.connHint ?? '已保存')),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _pair() async {
    final s = AppScope.of(context);
    final code = _code.text.trim();
    if (code.length < 6) {
      setState(() => _message = '配对码无效');
      return;
    }
    setState(() => _busy = true);
    final r = await s.pair(code);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = r.ok ? '配对成功' : '配对失败：${r.friendlyError}';
    });
  }

  /// 扫码配对：地址和码一起换。
  Future<void> _scan() async {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final result = await Navigator.of(context).push<PairScanResult>(
      MaterialPageRoute(builder: (_) => ScanPage(dark: dark)),
    );
    if (result == null || !mounted) return;

    final s = AppScope.of(context);
    setState(() {
      _busy = true;
      // 把扫到的码回填到输入框，用户能看到具体用了什么
      _code.text = result.code;
      _message = result.baseUrl.isEmpty
          ? '已识别配对码，正在配对…'
          : '已识别 ${result.baseUrl}，正在配对…';
    });

    final r = await s.pairFromScan(result);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = r.ok
          ? '配对成功'
          : '配对失败：${r.friendlyError}';
    });
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final c = DshColors.of(dark);

    return Scaffold(
      appBar: AppBar(title: const Text('连接设置')),
      /*
       * 键盘避让 —— 阶段①实测踩到的真问题。
       *
       * 原来直接把 ListView 放在 Scaffold 里，键盘弹出后「保存」按钮被盖住，
       * 点击落空、界面上什么都不会发生。用户以为按钮坏了。
       *
       * 三步一起做才稳：
       *   1. `resizeToAvoidBottomInset: true`（Scaffold 默认）让 body 缩短
       *   2. ListView 本身可滚 —— 内容比可视区高时能滚到按钮
       *   3. `padding` 把 viewInsets.bottom 也算进去，避免最后一项被
       *      键盘边缘裁掉一半
       */
      resizeToAvoidBottomInset: true,
      body: Builder(
        builder: (ctx) {
          final insets = MediaQuery.viewInsetsOf(ctx);
          return ListView(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + insets.bottom),
            children: [
          FluentCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('网络模式', style: TextStyle(color: c.textPrimary, fontWeight: FontWeight.bold, fontSize: 13)),
                const SizedBox(height: 8),
                SegmentedButton<NetMode>(
                  segments: const [
                    ButtonSegment(value: NetMode.lan, label: Text('局域网')),
                    ButtonSegment(value: NetMode.wan, label: Text('公网')),
                  ],
                  selected: {_mode},
                  onSelectionChanged: (v) => setState(() => _mode = v.first),
                ),
                const SizedBox(height: 14),
                /*
                 * hintText 必须是**通用示例**，不能写作者的真实地址。
                 *
                 * 这里曾经填的是作者家里的局域网 IP 和真实公网域名 ——
                 * 两个问题：① 泄露私有网络拓扑；② 新用户会误以为那是
                 * 预填好的值，直接点保存然后连不上，还以为是软件坏了。
                 */
                TextField(
                  controller: _lan,
                  decoration: const InputDecoration(
                    labelText: '局域网地址',
                    hintText: 'http://192.168.1.10:19387',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _wan,
                  decoration: const InputDecoration(
                    labelText: '公网地址',
                    hintText: 'https://dsh.example.com',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    FilledButton(
                      onPressed: _busy ? null : _save,
                      child: const Text('保存'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          FluentCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('配对', style: TextStyle(color: c.textPrimary, fontWeight: FontWeight.bold, fontSize: 13)),
                const SizedBox(height: 4),
                Text(
                  '在电脑上打开 DSH 侧边栏底部「配对我的手机」，读 6 位码填这里，'
                  '或者直接扫那个二维码。',
                  style: TextStyle(color: c.textTertiary, fontSize: 11.5),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _code,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  decoration: const InputDecoration(
                    labelText: '配对码',
                    hintText: '6 位数字',
                    border: OutlineInputBorder(),
                  ),
                ),
                Row(
                  children: [
                    FilledButton(
                      onPressed: _busy ? null : _pair,
                      child: const Text('配对'),
                    ),
                    const SizedBox(width: 10),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _scan,
                      icon: DshIcon(DshGlyph.scan, size: 17, color: c.accent),
                      label: Text(
                        '扫码配对',
                        style: TextStyle(fontSize: 13, color: c.accent),
                      ),
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(color: c.accent, width: 1),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ],
                ),
                if (_message != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    _message!,
                    style: TextStyle(
                      color: _message!.contains('成功') || _message!.contains('正常')
                          ? c.success
                          : c.danger,
                      fontSize: 12.5,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
          );
        },
      ),
    );
  }
}









