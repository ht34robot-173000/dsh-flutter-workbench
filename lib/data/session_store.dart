/// DSH 工作台 —— 会话列表的**进程内缓存**。
///
/// 为什么要有这一层（而不是把状态放在页面里）：
///
///   1. **切主题别再打请求**。页面 State 一旦被销毁重建（历史版本里切换主题
///      就会发生，见 `theme_reveal.dart` 头部的解释），数据在 State 里就跟着没了，
///      界面掉回转圈。搬到全局 store 之后，重建也能**立刻**画出上次的数据。
///   2. **切页签不重拉**。底部「对话 / 我的」来回切，列表不该重新加载。
///   3. **返回时秒开**。从文件管理 / 设置页返回，先显示缓存，再静默刷新。
///
/// 规矩：
///   - `data == null` 才算「首次加载」，才允许显示转圈；
///   - 有数据后的刷新一律**静默**（不闪、不跳滚动位置）；
///   - 新鲜期内的重复 `load()` 直接短路，不产生请求；
///   - 地址 / 配对变化时调 `reset()`，否则会拿着另一台机器的列表。
library;

import 'package:flutter/foundation.dart';

import 'ds_api.dart';
import 'session_data.dart';

class SessionStore extends ChangeNotifier {
  SessionStore._();

  /// 全 App 一个实例。会话列表本来就只有一个来源。
  static final SessionStore instance = SessionStore._();

  SessionListData? data;

  /// 最近一次失败的提示。有缓存数据时不覆盖界面，只留作下拉刷新的提示。
  String? error;

  bool loading = false;
  DateTime? fetchedAt;

  /// 在这个窗口内重复调用 `load()` 直接返回。
  ///
  /// 15 秒是个折中：切页签、切主题、返回列表都在几秒内，不该打请求；
  /// 而用户真在等新数据时会主动下拉刷新（那走 `force: true`）。
  static const freshFor = Duration(seconds: 15);

  bool get hasData => data != null;

  /// 拉一次列表。
  ///
  /// [force] 为 true 时忽略新鲜期（下拉刷新、错误后重试）。
  Future<void> load(DshApi api, {bool force = false}) async {
    if (loading) return;
    final at = fetchedAt;
    if (!force &&
        data != null &&
        at != null &&
        DateTime.now().difference(at) < freshFor) {
      return;
    }

    loading = true;
    // 已经有数据时不要通知「加载中」——那会让界面闪一下
    if (data == null) notifyListeners();

    ApiResult r;
    try {
      r = await api.api('session.list');
    } catch (e) {
      r = ApiResult.network('请求失败：$e');
    }

    loading = false;
    if (!r.ok) {
      // 有旧数据就保留界面，只记下错误（下次进页面还能看到东西）
      error = r.friendlyError;
      notifyListeners();
      return;
    }

    // 宿主返回两种形状都认：value 直接是数组，或 value.items / value.sessions
    final v = r.value?['value'];
    List<dynamic> raw = const [];
    if (v is List) {
      raw = v;
    } else if (v is Map) {
      final items = v['items'] ?? v['sessions'];
      if (items is List) raw = items;
    }

    data = SessionListData.fromJson(raw);
    error = null;
    fetchedAt = DateTime.now();
    notifyListeners();
  }

  /// 地址、配对、账号变了 —— 旧列表已经不代表当前服务器，必须扔掉。
  void reset() {
    data = null;
    error = null;
    loading = false;
    fetchedAt = null;
    notifyListeners();
  }
}
