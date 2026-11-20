/// DSH 远程工作台 —— 配置持久化。
///
/// 字段名**刻意与 Kotlin 版对齐**（`net_mode` / `url_lan` / `url_wan` /
/// `cookie_lan` / `cookie_wan`）。理由是迁移期两个 App 会同时装着，
/// 排查问题时能拿着同一套键名对照，不用心算换算。
///
/// 为什么不直接共用同一个 SharedPreferences 文件：两个 App 包名不同
/// （`com.dsh.workbench` vs `com.dsh.flutter_workbench`），Android 的
/// SharedPreferences 是按包名隔离的，物理上就共享不了。所以这里只是**键名对齐**。
library;

import 'package:shared_preferences/shared_preferences.dart';

/// 网络模式。局域网直连宿主，公网走 Cloudflare named tunnel。
enum NetMode { lan, wan }

class Prefs {
  static const _kMode = 'net_mode';
  static const _kUrlLan = 'url_lan';
  static const _kUrlWan = 'url_wan';
  static const _kCookieLan = 'cookie_lan';
  static const _kCookieWan = 'cookie_wan';
  static const _kTheme = 'theme';
  static const _kShowUngrouped = 'show_ungrouped';
  static const _kShowArchived = 'show_archived';

  /// 老版本的键，只用于迁移（Kotlin 版 v3.0 之前只有 base_url 一个地址）
  static const _kLegacyUrl = 'base_url';
  static const _kLegacyCookie = 'cookie';

  final SharedPreferences _sp;

  Prefs(this._sp);

  static Future<Prefs> load() async {
    final sp = await SharedPreferences.getInstance();
    final p = Prefs(sp);
    await p._migrateLegacy();
    return p;
  }

  /// 老数据迁移。
  ///
  /// Kotlin 版踩过的坑：老版本只存 `base_url` 一个地址，升级后如果不迁移，
  /// 用户会看到地址框是空的，而且报错信息指向「查不到宿主状态」——
  /// 完全指不到真实原因。这里按地址长相判断归属：
  /// 私有网段/localhost 归局域网格，其余归公网格。
  Future<void> _migrateLegacy() async {
    final legacy = _sp.getString(_kLegacyUrl);
    if (legacy == null || legacy.isEmpty) return;

    final isLan = _looksLikeLan(legacy);
    if (isLan) {
      if ((_sp.getString(_kUrlLan) ?? '').isEmpty) {
        await _sp.setString(_kUrlLan, legacy);
      }
    } else {
      if ((_sp.getString(_kUrlWan) ?? '').isEmpty) {
        await _sp.setString(_kUrlWan, legacy);
      }
    }

    final legacyCk = _sp.getString(_kLegacyCookie);
    if (legacyCk != null && legacyCk.isNotEmpty) {
      final key = isLan ? _kCookieLan : _kCookieWan;
      if ((_sp.getString(key) ?? '').isEmpty) {
        await _sp.setString(key, legacyCk);
      }
    }

    await _sp.remove(_kLegacyUrl);
    await _sp.remove(_kLegacyCookie);
  }

  static bool _looksLikeLan(String url) {
    final host = Uri.tryParse(url)?.host ?? '';
    if (host.isEmpty) return false;
    if (host == 'localhost' || host == '127.0.0.1') return true;
    if (host.startsWith('192.168.')) return true;
    if (host.startsWith('10.')) return true;
    if (RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(host)) return true;
    return false;
  }

  // ——————— 模式 ———————

  NetMode get mode =>
      (_sp.getString(_kMode) ?? 'lan') == 'wan' ? NetMode.wan : NetMode.lan;

  Future<void> setMode(NetMode m) =>
      _sp.setString(_kMode, m == NetMode.wan ? 'wan' : 'lan');

  // ——————— 地址 ———————

  String get lanUrl => _normalize(_sp.getString(_kUrlLan) ?? '');
  String get wanUrl => _normalize(_sp.getString(_kUrlWan) ?? '');

  Future<void> setLanUrl(String v) => _sp.setString(_kUrlLan, _normalize(v));
  Future<void> setWanUrl(String v) => _sp.setString(_kUrlWan, _normalize(v));

  /// 当前模式对应的地址。空串表示还没配。
  String get baseUrl => mode == NetMode.lan ? lanUrl : wanUrl;

  // ——————— 应用内更新 ———————
  //
  // 仓库名和 API 源都要可配，原因：GitHub 账号可能被停用（已发生过一次），
  // 或者用户 fork 了自己的仓库、或者国内 api.github.com 不可达要换反代。
  // 写死在源码里就等于「出事只能改代码重发版」—— 而更新通道本身坏了就发不了版。

  static const _kUpdateRepo = 'update_repo';
  static const _kUpdateApi = 'update_api';

  /// 更新用的仓库，`owner/repo` 形式。空串用默认。
  String get updateRepo {
    final v = (_sp.getString(_kUpdateRepo) ?? '').trim();
    return v.isEmpty ? 'ht34robot-173000/dsh-flutter-workbench' : v;
  }

  Future<void> setUpdateRepo(String v) =>
      _sp.setString(_kUpdateRepo, v.trim());

  /// GitHub API 源。空串用默认 `https://api.github.com`。
  String get updateApi {
    final v = (_sp.getString(_kUpdateApi) ?? '').trim();
    if (v.isEmpty) return 'https://api.github.com';
    return v.endsWith('/') ? v.substring(0, v.length - 1) : v;
  }

  Future<void> setUpdateApi(String v) =>
      _sp.setString(_kUpdateApi, v.trim());

  // ——————— 设备 cookie ———————
  //
  // **必须按模式分开存**：局域网直连宿主、公网走 Cloudflare 反代，
  // authority 不同 → 宿主签出来的设备 cookie 也不同。共用一份必然 401。
  // 这是 Kotlin 版踩过的坑，标记在这免得重犯。

  String? get cookie => mode == NetMode.lan
      ? _sp.getString(_kCookieLan)
      : _sp.getString(_kCookieWan);

  Future<void> setCookie(String? v) async {
    if (v == null || v.isEmpty) {
      await _sp.remove(mode == NetMode.lan ? _kCookieLan : _kCookieWan);
    } else {
      await _sp.setString(mode == NetMode.lan ? _kCookieLan : _kCookieWan, v);
    }
  }

  // ——————— 主题 ———————
  //
  // 只存 light / dark 两种。
  //
  // ⚠️ Kotlin 版在这里踩过一个**让用户反复报「白天切不了」**的坑：
  // 老实现有第三档 `system`，而切换逻辑是 system→light→dark→system 轮换。
  // 白天系统是浅色，于是「system(浅)→light(浅)」界面毫无变化 ——
  // 用户点了没反应，还必须再点一下才变黑。截图逐字节比对确认过。
  //
  // 所以这里干脆不提供 system 档参加轮换：切换永远按「当前实际明暗」取反。

  bool get isDark => (_sp.getString(_kTheme) ?? 'light') == 'dark';

  Future<void> setDark(bool dark) =>
      _sp.setString(_kTheme, dark ? 'dark' : 'light');

  /* ---------------- 列表显示偏好 ---------------- */

  /// 是否把「未分组」（没有归属工作区的会话）显示在列表里。
  ///
  /// 这些会话大多来自临时目录，混在工作区分组后面会让列表显得没收拾；
  /// 但也有人就是靠它找旧会话，所以做成开关，默认**显示**。
  bool get showUngrouped =>
      (_sp.getString(_kShowUngrouped) ?? '1') == '1';

  Future<void> setShowUngrouped(bool v) =>
      _sp.setString(_kShowUngrouped, v ? '1' : '0');

  /// 是否显示「已归档」。默认**不显示** —— 归档本来就是为了收起来。
  bool get showArchived => (_sp.getString(_kShowArchived) ?? '0') == '1';

  Future<void> setShowArchived(bool v) =>
      _sp.setString(_kShowArchived, v ? '1' : '0');

  /// 规范化地址：补 scheme、去尾部斜杠。
  ///
  /// 用户手输 `192.168.1.10:19387` 是常态，不能要求他写全 `http://`。
  /// 有明确 https:// 就保留；私有地址一律按 http 补（自签/无证书场景更常见）。
  static String _normalize(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return '';
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    if (s.isEmpty) return '';
    if (s.startsWith('http://') || s.startsWith('https://')) return s;
    return 'http://$s';
  }
}

