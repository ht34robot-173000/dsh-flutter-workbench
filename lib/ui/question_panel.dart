/// DSH 工作台 —— 「手机端回答 DSH 提问」卡片（对话页底部）。
///
/// 为什么需要这块：`ask_user_question` 是 agent **阻塞等人**的工具。
/// 默认 `legacy` 模式下它不写 `userQuestions` 投影，远端永远看不到「有题在等我答」，
/// 会话就永久卡死。宿主 preset 已改成 `mode: timed`（timeout 300），
/// 于是题目会以 `active[]` 的形式出现，这里负责把它显示出来并允许在手机上回答。
///
/// 交互与状态（`open` / `continued` 的差别见 `data/questions_api.dart` 文件头）：
///
///   `open`      —— 工具调用还挂着。提交会被宿主静默吃掉，所以**按钮必须禁用**，
///                  同时每 5 秒轮询一次等它转成 `continued`。
///   `continued` —— 可补答。这时提交才会真的 steer 一条答复给 agent。
///
/// ⚠️ **不要用系统 CheckBox / Switch / AlertDialog**（交接文档第七节硬性规范）：
/// 自绘符号 + 文字双重表达状态，`☑/☐`（多选）、`●/○`（单选）。
/// 只改颜色的话，选中和未选中看起来一样，人和自动化都判断不出选没选。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../data/ds_api.dart';
import '../data/questions_api.dart';
import 'icons.dart';
import 'theme.dart';

class QuestionPanel extends StatefulWidget {
  final DshApi api;
  final String sessionId;
  final bool dark;

  /// 外部（对话页）在「可能出现了新提问」时递增它，面板据此重新拉取。
  ///
  /// 为什么用计数器而不是让面板自己订阅 SSE：`LiveClient.connect()` 返回的是
  /// **单订阅** Stream（宿主那侧一条连接），对话页已经 listen 了，
  /// 面板再 listen 会直接抛 `Stream has already been listened to`。
  final int refreshTick;

  /// 提交成功后回调（对话页用来刷新历史/滚动）。
  final VoidCallback? onAnswered;

  const QuestionPanel({
    super.key,
    required this.api,
    required this.sessionId,
    required this.dark,
    this.refreshTick = 0,
    this.onAnswered,
  });

  @override
  State<QuestionPanel> createState() => _QuestionPanelState();
}

class _QuestionPanelState extends State<QuestionPanel> {
  late final QuestionsApi _qapi = QuestionsApi(widget.api);

  QuestionsView _view = QuestionsView.empty;
  bool _loading = false;
  String? _error;
  String? _notice;

  /// 正在提交的批次 callId（只锁那一个批次）。
  String? _submitting;

  bool _collapsed = false;

  /// 草稿与输入框。key = `callId::questionId`。
  ///
  /// 必须挂在 State 上而不是就地 new：面板每次 `setState` 都会重建，
  /// 就地建 `TextEditingController` 会**丢掉用户已经敲进去的字**。
  final _drafts = <String, QuestionDraft>{};
  final _ctrls = <String, TextEditingController>{};

  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  @override
  void didUpdateWidget(QuestionPanel old) {
    super.didUpdateWidget(old);
    if (old.refreshTick != widget.refreshTick) _fetch();
  }

  @override
  void dispose() {
    _poll?.cancel();
    for (final c in _ctrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  String _key(String callId, String qid) => '$callId::$qid';

  TextEditingController _ctrlOf(String key) =>
      _ctrls.putIfAbsent(key, () => TextEditingController());

  QuestionDraft _draftOf(String key) => _drafts[key] ?? const QuestionDraft();

  /* ---------------- 拉取 ---------------- */

  Future<void> _fetch() async {
    if (_loading) return;
    setState(() => _loading = true);
    final r = await _qapi.fetch(widget.sessionId);
    if (!mounted) return;

    if (!r.ok) {
      setState(() {
        _loading = false;
        // 网络抖动不要清掉已经显示出来的卡片，否则用户填了一半的答案「消失」
        _error = _view.hasActive ? null : r.friendlyError;
      });
      return;
    }

    final view = QuestionsView.fromValue(r.value?['value'] as Map<String, dynamic>?);
    setState(() {
      _loading = false;
      _error = null;
      _view = view;
      _notice = null;

      // 清掉已经不在 active 里的草稿/输入框（答完的、放弃的）
      final alive = <String>{
        for (final b in view.active)
          for (final q in b.questions) _key(b.callId, q.id),
      };
      _drafts.removeWhere((k, _) => !alive.contains(k));
      for (final k in _ctrls.keys.toList()) {
        if (!alive.contains(k)) {
          _ctrls.remove(k)?.dispose();
        }
      }
    });

    _armPolling();
  }

  /// `open` 状态的批次需要盯着它转 `continued`（宿主那边超时后才会写）。
  ///
  /// 只在这种情况下轮询：平时靠对话页的 live 事件触发 `refreshTick`，
  /// 不做无谓的定时请求（手机走上行，请求越小越好）。
  void _armPolling() {
    _poll?.cancel();
    _poll = null;
    if (!_view.active.any((b) => b.isOpen)) return;
    _poll = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      if (_view.active.any((b) => b.isOpen)) _fetch();
    });
  }

  /* ---------------- 作答 ---------------- */

  Future<void> _submit(QuestionBatch batch) async {
    if (_submitting != null || !batch.answerable) return;

    final answers = buildAnswers(
      batch.questions,
      {
        for (final q in batch.questions) q.id: _draftOf(_key(batch.callId, q.id)),
      },
    );

    setState(() {
      _submitting = batch.callId;
      _error = null;
      _notice = null;
    });

    final r = await _qapi.answer(
      sessionId: widget.sessionId,
      callId: batch.callId,
      answers: answers,
    );
    if (!mounted) return;

    setState(() => _submitting = null);

    if (!r.ok) {
      // 这里**不能**假装成功：`question-still-open` / `bad-answer` 都设计成
      // 「如实告诉用户发生了什么」，宿主那边的 message 已经是人话。
      setState(() => _error = r.friendlyError);
      _fetch();
      return;
    }

    final answered = r.value?['value']?['answered'] != false;
    setState(() {
      _notice = answered ? '已提交，答案会送达 agent' : '宿主没接受这条答复（可能已超时关闭）';
    });
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(_notice!)));

    widget.onAnswered?.call();
    await _fetch();
  }

  /* ---------------- 渲染 ---------------- */

  @override
  Widget build(BuildContext context) {
    if (_view.active.isEmpty) {
      // 没有待答的题就什么都不占位（连一条分隔线都不留）
      if (_error == null) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 8),
        child: Text(
          _error!,
          style: TextStyle(
            fontSize: 11.5,
            color: DshColors.of(widget.dark).danger,
          ),
        ),
      );
    }

    final c = DshColors.of(widget.dark);
    final total = _view.active.fold<int>(0, (n, b) => n + b.questions.length);

    return Container(
      decoration: BoxDecoration(
        color: c.sheetFill.withValues(alpha: 0.97),
        border: Border(top: BorderSide(color: c.stroke)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _header(c, total),
          if (!_collapsed) ...[
            const SizedBox(height: 8),
            /*
             * 高度上限 + 内部滚动。
             *
             * 交接文档第七节的硬性要求：内容多的面板**不能靠 WRAP_CONTENT**
             * 撑高（超出屏幕会被裁掉，「重启 DSH」按钮就是这么消失过一次）。
             */
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.38,
              ),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final b in _view.active) _buildBatch(c, b),
                  ],
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 6),
              Text(
                _error!,
                style: TextStyle(fontSize: 11.5, color: c.danger),
              ),
            ],
            if (_notice != null) ...[
              const SizedBox(height: 6),
              Text(
                _notice!,
                style: TextStyle(fontSize: 11.5, color: c.success),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _header(DshColors c, int total) {
    final blocked = _view.active.every((b) => !b.answerable);
    return Row(
      children: [
        DshIcon(DshGlyph.chat, size: 15, color: c.accent),
        const SizedBox(width: 7),
        Text(
          'DSH 在等你回答',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: c.textPrimary,
          ),
        ),
        const SizedBox(width: 7),
        Text(
          '$total 题',
          style: TextStyle(fontSize: 11, color: c.textTertiary),
        ),
        const SizedBox(width: 7),
        // 状态胶囊：能答 / 还不能答，用文字说清楚，不靠颜色暗示
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: blocked
                ? c.textTertiary.withValues(alpha: 0.14)
                : c.success.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            blocked ? '等桌面端窗口关闭' : '可补答',
            style: TextStyle(
              fontSize: 10,
              color: blocked ? c.textSecondary : c.success,
            ),
          ),
        ),
        const Spacer(),
        if (_loading)
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 1.6, color: c.accent),
          )
        else
          IconButton(
            icon: DshIcon(DshGlyph.refresh, size: 14, color: c.textSecondary),
            onPressed: _fetch,
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            tooltip: '刷新',
          ),
        IconButton(
          icon: DshIcon(
            _collapsed ? DshGlyph.expandMore : DshGlyph.expandLess,
            size: 14,
            color: c.textSecondary,
          ),
          onPressed: () => setState(() => _collapsed = !_collapsed),
          padding: const EdgeInsets.all(4),
          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          tooltip: _collapsed ? '展开' : '收起',
        ),
      ],
    );
  }

  Widget _buildBatch(DshColors c, QuestionBatch b) {
    final busy = _submitting == b.callId;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < b.questions.length; i++)
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0 : 12),
            child: _buildQuestion(c, b, b.questions[i], i + 1, b.questions.length),
          ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: Text(
                b.isOpen
                    ? 'agent 正阻塞等桌面端回答；超时后（约 5 分钟）这里会自动变成可补答'
                    : '没选的题会当作跳过；也可以直接发消息推进任务',
                style: TextStyle(fontSize: 10.5, color: c.textTertiary, height: 1.3),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              height: 32,
              child: FilledButton(
                // open 时提交会被静默吃掉 → 直接禁用，别让用户白点
                onPressed: (busy || !b.answerable) ? null : () => _submit(b),
                style: FilledButton.styleFrom(
                  backgroundColor: c.accent,
                  foregroundColor: c.onAccent,
                  disabledBackgroundColor: c.stroke,
                  disabledForegroundColor: c.textTertiary,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: busy
                    ? SizedBox(
                        width: 13,
                        height: 13,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: c.onAccent,
                        ),
                      )
                    : const Text('提交', style: TextStyle(fontSize: 12.5)),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildQuestion(
    DshColors c,
    QuestionBatch b,
    AskQuestion q,
    int index,
    int total,
  ) {
    final key = _key(b.callId, q.id);
    final draft = _draftOf(key);
    final enabled = b.answerable;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$index.',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: c.textTertiary,
              ),
            ),
            const SizedBox(width: 4),
            if (q.header != null) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: c.accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  q.header!,
                  style: TextStyle(fontSize: 9.5, color: c.accent),
                ),
              ),
              const SizedBox(width: 5),
            ],
            Expanded(
              child: Text(
                q.text,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.35,
                  fontWeight: FontWeight.w600,
                  color: c.textPrimary,
                ),
              ),
            ),
            Text(
              q.multiSelect ? '多选' : '单选',
              style: TextStyle(fontSize: 9.5, color: c.textTertiary),
            ),
          ],
        ),
        if (q.detail != null) ...[
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxHeight: 120),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: c.inputFill,
              borderRadius: BorderRadius.circular(7),
              border: Border.all(color: c.stroke),
            ),
            child: SingleChildScrollView(
              child: Text(
                q.detail!,
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.4,
                  color: c.textSecondary,
                ),
              ),
            ),
          ),
        ],
        if (q.hasOptions) ...[
          const SizedBox(height: 6),
          for (final o in q.options) _buildOption(c, key, q, o, draft, enabled),
        ],
        const SizedBox(height: 6),
        TextField(
          controller: _ctrlOf(key),
          enabled: enabled,
          style: TextStyle(fontSize: 12.5, color: c.textPrimary),
          decoration: InputDecoration(
            hintText: q.multiSelect
                ? '补充说明（可选，会和上面的选项一起提交）'
                : (q.hasOptions ? '或者自己填一个答案（会覆盖上面的选择）' : '输入你的回答'),
            hintStyle: TextStyle(fontSize: 12, color: c.textTertiary),
            filled: true,
            fillColor: c.inputFill,
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: c.stroke),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: c.stroke),
            ),
          ),
          onChanged: (v) {
            _drafts[key] = _draftOf(key).copyWith(custom: v);
          },
        ),
      ],
    );
  }

  Widget _buildOption(
    DshColors c,
    String key,
    AskQuestion q,
    QuestionOption o,
    QuestionDraft draft,
    bool enabled,
  ) {
    final on = draft.selected.contains(o.label);
    /*
     * ⚠️ 符号本身就是状态（交接文档 16.6）：
     *   多选 ☑ / ☐        单选 ● / ○
     * 早先只 setTextColor + 加粗，实测「选中和未选中看起来一样」。
     */
    final symbol = q.multiSelect
        ? (on ? '☑' : '☐')
        : (on ? '●' : '○');

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(7),
          onTap: enabled
              ? () => setState(() {
                    _drafts[key] = draft.toggle(
                      o.label,
                      multi: q.multiSelect,
                    );
                  })
              : null,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: on ? c.accent.withValues(alpha: 0.12) : Colors.transparent,
              borderRadius: BorderRadius.circular(7),
              border: Border.all(color: on ? c.accent.withValues(alpha: 0.5) : c.stroke),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  symbol,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.2,
                    color: on ? c.accent : c.textTertiary,
                  ),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        o.label,
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.3,
                          color: c.textPrimary,
                          fontWeight: on ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                      if (o.description != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          o.description!,
                          style: TextStyle(
                            fontSize: 10.5,
                            height: 1.3,
                            color: c.textTertiary,
                          ),
                        ),
                      ],
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
}
