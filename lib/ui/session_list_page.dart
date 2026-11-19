/// DSH 工作台 —— 会话列表页。
///
/// ⚠️ 对齐标准（2026-11-19 调整，与 workbench_shell 同一原则）：
///
/// 这里**不逐个元素对齐 Kotlin 版的像素**。Kotlin 是手写 LinearLayout +
/// 自定义 px padding 拼的，Flutter 的 flex + Text 行高天然不同，
/// 硬凑只会让元素错位（阶段②实测：为凑卡片高度调 TextStyle.height，
/// 把图标挤到文字上方，连改四轮）。
///
/// 保留一致的是：
///   ✅ 配色令牌（暗 #000000 底 / #0F0F0F 卡；亮 #F9F9F9 底 / 白卡）
///   ✅ 分组结构（▼/▶ + 组名 + 计数，可折叠）
///   ✅ 每组顶部一行「新会话」（淡主色底 + 主色描边 + 加号）
///   ✅ 会话卡（标题 + 时间，圆角描边，无阴影）
///   ✅ 时间格式 `MM-dd HH:mm`（两版必须一致，否则并排看会以为数据错了）
library;

import 'package:flutter/material.dart';

import '../data/ds_api.dart';
import '../data/session_data.dart';
import 'icons.dart';
import 'theme.dart';

class SessionListPage extends StatefulWidget {
  final DshApi api;
  final bool dark;
  final void Function(SessionItem)? onOpenSession;

  const SessionListPage({
    super.key,
    required this.api,
    required this.dark,
    this.onOpenSession,
  });

  @override
  State<SessionListPage> createState() => _SessionListPageState();
}

class _SessionListPageState extends State<SessionListPage> {
  SessionListData? _data;
  String? _error;
  bool _loading = true;

  /// 折叠的分组。Kotlin 版落盘到 prefs.expandedWorkspaces，
  /// 这里先放内存 —— 阶段②只要求列表能用，持久化下一阶段补。
  final Set<String> _collapsed = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // 「加载中」只在首次显示。后续刷新走静默合并，
    // 否则列表会闪一下、滚动位置跳到顶（踩坑文档 4.6）。
    if (_data == null) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    final r = await widget.api.api('session.list');
    if (!mounted) return;
    if (!r.ok) {
      setState(() {
        _loading = false;
        _error = r.friendlyError;
      });
      return;
    }
    // 宿主返回两种形状都认：value 直接是数组，或 value.items
    final v = r.value?['value'];
    List<dynamic> raw = const [];
    if (v is List) {
      raw = v;
    } else if (v is Map) {
      final items = v['items'] ?? v['sessions'];
      if (items is List) raw = items;
    }
    setState(() {
      _loading = false;
      _error = null;
      _data = SessionListData.fromJson(raw);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = DshColors.of(widget.dark);

    if (_loading) {
      return Center(child: CircularProgressIndicator(color: c.accent));
    }
    if (_error != null) {
      return _ThreeState.error(
        c: c,
        message: _error!,
        onRetry: _load,
      );
    }

    final groups = _data!.grouped(const {});
    if (groups.isEmpty) {
      return _ThreeState.empty(c: c, message: '还没有会话');
    }

    // 用 ListView.builder 而不是把全部行塞进 children：
    // 264 条会话全铺出来会一次性建大量 widget（踩坑文档 35）。
    // 这里先把结构拍平成 (类型, 数据) 列表，再懒加载。
    final rows = <_Row>[];
    for (var gi = 0; gi < groups.length; gi++) {
      final g = groups[gi];
      final open = !_collapsed.contains(g.name);
      if (gi > 0) rows.add(_Row.divider());
      rows.add(_Row.group(g, open));
      if (!open) continue;
      rows.add(_Row.newSession());
      for (final s in g.items) {
        rows.add(_Row.session(s));
      }
    }

    return RefreshIndicator(
      color: c.accent,
      onRefresh: _load,
      child: ListView.builder(
        // 不对齐 Kotlin 的 (8,4,8,8)：这里给一个读着舒服的边距，
        // 但要显式写全四个值，否则 ListView 会自动叠加 MediaQuery 的 inset
        padding: const EdgeInsets.fromLTRB(10, 4, 10, 12),
        itemCount: rows.length,
        itemBuilder: (context, i) {
          final r = rows[i];
          switch (r.kind) {
            case _RowKind.divider:
              return Padding(
                padding: const EdgeInsets.only(top: 12, bottom: 4),
                child: Container(height: 1, color: c.stroke),
              );
            case _RowKind.group:
              return _groupHeader(c, r.group!, r.open!);
            case _RowKind.newSession:
              return _newSessionRow(c);
            case _RowKind.session:
              return _sessionCard(c, r.session!);
          }
        },
      ),
    );
  }

  Widget _groupHeader(DshColors c, SessionGroup g, bool open) {
    return InkWell(
      onTap: () => setState(() {
        if (open) {
          _collapsed.add(g.name);
        } else {
          _collapsed.remove(g.name);
        }
      }),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
        child: Row(
          children: [
            // 折叠指示。用 Icon 不用 ▼/▶ 字符：
            // 那两个字符在部分字体下会被 emoji 回退链接走，渲染成彩色方块
            AnimatedRotation(
              turns: open ? 0 : -0.25,
              duration: const Duration(milliseconds: 150),
              child: DshIcon(
                DshGlyph.expandMore,
                size: 16,
                color: c.textTertiary,
              ),
            ),
            const SizedBox(width: 4),
            Text(
              g.name,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: c.textPrimary,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '${g.count}',
              style: TextStyle(fontSize: 11, color: c.textTertiary),
            ),
          ],
        ),
      ),
    );
  }

  Widget _newSessionRow(DshColors c) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 2, 2, 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('新建会话在阶段③接入')),
          );
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          decoration: BoxDecoration(
            // 淡主色铺底：暗色 14% 蓝 / 亮色 10% 蓝 —— 和会话卡的
            // 中性底色明显区分，一眼看出这是「操作入口」不是「内容」
            color: widget.dark
                ? const Color(0x2460A5FA)
                : const Color(0x1A005FB8),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: c.accent, width: 1),
          ),
          child: Row(
            children: [
              DshIcon(DshGlyph.plus, size: 17, color: c.accent),
              const SizedBox(width: 8),
              Text(
                '新会话',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: c.accent,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sessionCard(DshColors c, SessionItem s) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () {
          if (widget.onOpenSession != null) {
            widget.onOpenSession!(s);
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('对话页在阶段③接入：${s.title}')),
            );
          }
        },
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          decoration: BoxDecoration(
            // 暗色 #0F0F0F 比纯黑略提亮，靠 1px 描边分层（不用阴影）
            color: widget.dark
                ? const Color(0xFF0F0F0F)
                : const Color(0xB8FFFFFF),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: c.stroke, width: 1),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                s.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13.5, color: c.textPrimary),
              ),
              const SizedBox(height: 3),
              Text(
                formatSessionTime(s.updatedAt),
                style: TextStyle(fontSize: 11, color: c.textTertiary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/* ---------------- 拍平用的行模型 ---------------- */

enum _RowKind { divider, group, newSession, session }

class _Row {
  final _RowKind kind;
  final SessionGroup? group;
  final bool? open;
  final SessionItem? session;

  const _Row._(this.kind, {this.group, this.open, this.session});

  factory _Row.divider() => const _Row._(_RowKind.divider);
  factory _Row.group(SessionGroup g, bool open) =>
      _Row._(_RowKind.group, group: g, open: open);
  factory _Row.newSession() => const _Row._(_RowKind.newSession);
  factory _Row.session(SessionItem s) =>
      _Row._(_RowKind.session, session: s);
}

/* ---------------- 加载 / 错误 / 空 三态 ---------------- */

class _ThreeState {
  static Widget error({
    required DshColors c,
    required String message,
    required VoidCallback onRetry,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DshIcon(DshGlyph.info, size: 34, color: c.danger),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: c.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }

  static Widget empty({required DshColors c, required String message}) {
    return Center(
      child: Text(
        message,
        style: TextStyle(color: c.textTertiary, fontSize: 12.5),
      ),
    );
  }
}
