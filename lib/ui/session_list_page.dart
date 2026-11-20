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
import '../main.dart' show AppScope;
import '../data/session_data.dart';
import '../data/session_store.dart';
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
  /// 数据放在全局 store 里，**不在 State 里**。
  ///
  /// 这样即使这个页面被重建（切主题、切页签、返回再进），
  /// 也能立刻画出上次的列表：不转圈、不闪、滚动位置由 ListView 自己保住。
  final _store = SessionStore.instance;

  /// 折叠的分组。Kotlin 版落盘到 prefs.expandedWorkspaces，
  /// 这里先放内存 —— 阶段②只要求列表能用，持久化下一阶段补。
  final Set<String> _collapsed = {};

  @override
  void initState() {
    super.initState();
    // 新鲜期内会短路，不会每次都打请求
    _store.load(widget.api);
  }

  Future<void> _load() => _store.load(widget.api, force: true);

  @override
  Widget build(BuildContext context) {
    /*
     * 订阅 store：数据变了才重建。
     *
     * 三态的判据是**有没有数据**，不是「有没有在加载」：
     *   - 没数据 + 在加载        → 转圈（只有这一种情况允许转圈）
     *   - 没数据 + 有错误        → 错误页
     *   - 有数据（哪怕正在刷新） → 直接画列表，静默更新
     *
     * 切主题时页面根本不会重建（快照方案见 theme_reveal.dart 头部），
     * 就算哪天又被重建了，这里也是「零等待」直接出内容。
     */
    return ListenableBuilder(
      listenable: _store,
      builder: (context, _) {
        final c = DshColors.of(widget.dark);
        final data = _store.data;

        if (data == null) {
          final err = _store.error;
          if (err != null) {
            return _ThreeState.error(c: c, message: err, onRetry: _load);
          }
          return Center(child: CircularProgressIndicator(color: c.accent));
        }

        /*
         * 分组 = 工作区分组 + 「未分组」+ 「已归档」。
         *
         * 后两个各自受侧边栏的两个复选框控制（Prefs 落盘）：
         *   「未分组」= 没有归属工作区的会话（工作区被删/临时目录跑的），默认显示
         *   「已归档」= archived=true，默认**不显示**（归档本来就是为了收起来）
         *
         * 注意它们在 grouped() 之外拼进来：grouped() 只吐有工作区的 active 会话，
         * 直接把 `archivedItems` / `ungrouped` 追加在后面，顺序稳定、不影响工作区分组。
         */
        final state = AppScope.of(context);
        final groups = <SessionGroup>[
          ...data.grouped(const {}),
          if (state.showUngrouped && data.ungrouped.isNotEmpty)
            SessionGroup('未分组', [...data.ungrouped]
              ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt))),
          if (state.showArchived && data.archivedItems.isNotEmpty)
            SessionGroup('已归档', [...data.archivedItems]
              ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt))),
        ];
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
      },
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

  /* ---------------- 长按动作：重命名 / 归档 ---------------- */

  /// 长按会话卡弹的动作菜单。
  ///
  /// 为什么不放「删除」：宿主只有 `session.archive`（归档），没有删除接口 ——
  /// 给一个点了报错的按钮比不给更糟。要真删得去电脑上删会话目录。
  Future<void> _showSessionActions(DshColors c, SessionItem s) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: c.sheetFill,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      s.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: c.textPrimary,
                      ),
                    ),
                  ),
                  Text(
                    formatSessionTime(s.updatedAt),
                    style: TextStyle(fontSize: 11, color: c.textTertiary),
                  ),
                ],
              ),
            ),
            ListTile(
              titleAlignment: ListTileTitleAlignment.center,
              leading: DshIcon(DshGlyph.edit, size: 20, color: c.textPrimary),
              title: Text('重命名', style: TextStyle(color: c.textPrimary)),
              onTap: () {
                Navigator.pop(ctx);
                _renameSession(c, s);
              },
            ),
            ListTile(
              titleAlignment: ListTileTitleAlignment.center,
              leading: DshIcon(
                DshGlyph.archive,
                size: 20,
                color: c.textPrimary,
              ),
              title: Text(
                s.archived ? '取消归档' : '归档',
                style: TextStyle(color: c.textPrimary),
              ),
              subtitle: Text(
                s.archived ? '放回列表' : '从列表收起来（可在侧边栏打开显示）',
                style: TextStyle(color: c.textTertiary, fontSize: 11.5),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _archiveSession(s, !s.archived);
              },
            ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }

  /// 重命名。用自绘弹层（不用 AlertDialog：默认样式和 App 的卡片风格不一致）。
  Future<void> _renameSession(DshColors c, SessionItem s) async {
    final controller = TextEditingController(text: s.title);
    final ok = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black38,
      builder: (ctx) => Dialog(
        backgroundColor: c.sheetFill,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '重命名会话',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: c.textPrimary,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                maxLength: 60,
                style: TextStyle(fontSize: 13.5, color: c.textPrimary),
                decoration: InputDecoration(
                  isDense: true,
                  counterStyle: TextStyle(fontSize: 10, color: c.textTertiary),
                  filled: true,
                  fillColor: c.inputFill,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: c.stroke),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: c.stroke),
                  ),
                ),
                onSubmitted: (_) => Navigator.pop(ctx, true),
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: Text('取消', style: TextStyle(color: c.textSecondary)),
                  ),
                  const SizedBox(width: 6),
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    style: FilledButton.styleFrom(
                      backgroundColor: c.accent,
                      foregroundColor: c.onAccent,
                    ),
                    child: const Text('保存'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    final title = controller.text.trim();
    controller.dispose();
    if (ok != true || !mounted || title.isEmpty || title == s.title) return;

    final r = await widget.api.api('session.rename', {
      'sessionId': s.id,
      'title': title,
    });
    if (!mounted) return;
    if (!r.ok) {
      _toast('重命名失败：${r.friendlyError}');
      return;
    }
    _toast('已重命名为「$title」');
    await _load();
  }

  /// 归档 / 取消归档。
  Future<void> _archiveSession(SessionItem s, bool archived) async {
    final r = await widget.api.api('session.archive', {
      'sessionId': s.id,
      'archived': archived,
    });
    if (!mounted) return;
    if (!r.ok) {
      _toast('${archived ? '归档' : '取消归档'}失败：${r.friendlyError}');
      return;
    }
    _toast(archived ? '已归档，可在侧边栏打开「显示已归档」找回' : '已取消归档');
    await _load();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(msg, maxLines: 2, overflow: TextOverflow.ellipsis),
        duration: const Duration(seconds: 2),
      ));
  }

  Widget _sessionCard(DshColors c, SessionItem s) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        // 长按：重命名 / 归档（已归档的给「取消归档」）
        onLongPress: () => _showSessionActions(c, s),
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
