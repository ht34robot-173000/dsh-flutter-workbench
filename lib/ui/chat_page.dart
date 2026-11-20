/// DSH 工作台 —— 对话页（阶段③）。
///
/// 三件事：
///   1. 拉历史（`session.history`）渲染成气泡
///   2. 订阅 SSE，把 chunk 帧渲染成「进行中」气泡（逐字）
///   3. 发消息（`session.prompt`），**严格按宿主契约**组装 content 数组
///
/// ⚠️ 两条宿主契约（都是踩过的坑，见交接文档第五节）：
///
///   **坑 1：两种消息结构不一样**
///     user/message      → data 就是消息
///     assistant/message → data 里有 message 那一层
///   处理在 `chat_data.dart` 的 `ChatMessage.fromEvent`，这里不重复。
///
///   **坑 2：session.prompt 有严格契约**
///     宿主 `sessionController.prompt` 要的是：
///       { requestId, sessionId, mode: "queue"|"steer",
///         content: [{type:"text", text}] }
///     直接把 `{sessionId, text}` 丢过去，宿主会在 `content.some(...)`
///     处崩：`Cannot read properties of undefined (reading 'some')`。
///     发消息功能曾经一直是坏的，就是踩这个坑。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../data/chat_data.dart';
import '../data/ds_api.dart';
import '../data/live.dart';
import 'icons.dart';
import 'markdown_view.dart';
import 'question_panel.dart';
import 'theme.dart';

class ChatPage extends StatefulWidget {
  final DshApi api;
  final LiveClient live;
  final String sessionId;
  final String title;
  final bool dark;

  const ChatPage({
    super.key,
    required this.api,
    required this.live,
    required this.sessionId,
    required this.title,
    required this.dark,
  });

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _messages = <ChatMessage>[];

  /// 流式缓冲区。chunk 帧一路往里 append，渲染时作为一个「进行中」气泡。
  /// 正式 assistant/message 到达后清空 —— 那时内容已经在历史里了。
  final _streamBuf = StringBuffer();

  final _input = TextEditingController();
  final _scroll = ScrollController();

  StreamSubscription? _liveSub;
  bool _loading = true;
  String? _error;
  bool _running = false;
  bool _sending = false;

  /// 是否贴着底部。用户往上翻时不要把他拽回来。
  bool _stickToBottom = true;

  /// 历史游标（「加载更早」用）。
  bool _hasMore = false;
  double? _beforeSeq;

  /// 提问面板的刷新信号。
  ///
  /// 面板**不能自己订阅 SSE**：`LiveClient.connect()` 是单订阅流，
  /// 这里已经 listen 了，第二个监听会抛 `Stream has already been listened to`。
  /// 所以由本页在「可能出了新提问」时递增这个计数器，面板的
  /// `didUpdateWidget` 看到它变了就重新拉一次 `session.questions`。
  int _questionsTick = 0;

  /// 哪些「已回答提问」回执被展开了（按 seq 记）。
  /// 默认**全部收起** —— 和桌面端一致，不铺一屏原始 JSON。
  final _expandedReplies = <double>{};

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _loadHistory();
    _subscribe();
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _liveSub?.cancel();
    /*
     * 必须把这条 SSE 流关掉。
     *
     * ⚠️ `LiveClient.connect()` 给的是**单订阅流**，一辈子只能 listen 一次。
     * 只 cancel 不 close 的话，返回列表再进另一个对话页时，新页面的
     * `initState` 里 listen 会抛 `Bad state: Stream has already been listened to`，
     * 整页崩成灰屏（2026-11-20 实测：连开第三个会话必现）。
     */
    unawaited(widget.live.close());
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final gap = _scroll.position.maxScrollExtent - _scroll.position.pixels;
    _stickToBottom = gap < 80;
  }

  /* ---------------- 历史 ---------------- */

  Future<void> _loadHistory() async {
    if (mounted) setState(() => _loading = true);
    final r = await widget.api.api('session.history', {
      'sessionId': widget.sessionId,
      'maxMessages': 40,
    });
    if (!mounted) return;
    if (!r.ok) {
      setState(() {
        _loading = false;
        _error = r.friendlyError;
      });
      return;
    }
    final page = HistoryPage.fromJson(r.value?['value'] as Map<String, dynamic>?);
    setState(() {
      _loading = false;
      _error = null;

      /*
       * 合并历史，而不是直接覆盖。
       *
       * 历史请求是异步的，这期间 SSE 可能已经推进来新消息
       * （刚进对话页就有人在跑的情况）。直接 clear + addAll 会把
       * 那些新到的消息冲掉，用户看到的消息会「闪一下消失」。
       *
       * 做法：用 seq 去重合并，保留本地乐观消息（它们还没进历史）。
       */
      final existing = {for (final m in _messages) m.seq};
      final merged = <ChatMessage>[
        ...page.messages.where((m) => !existing.contains(m.seq)),
        ..._messages,
      ]..sort((a, b) => a.seq.compareTo(b.seq));
      _messages
        ..clear()
        ..addAll(merged);

      _hasMore = page.hasMore;
      _beforeSeq = page.beforeSeq;
    });
    _scrollToBottom(jump: true);
  }

  Future<void> _loadEarlier() async {
    if (_beforeSeq == null) return;
    final r = await widget.api.api('session.history', {
      'sessionId': widget.sessionId,
      'maxMessages': 40,
      'beforeSeq': _beforeSeq,
    });
    if (!mounted || !r.ok) return;
    final page = HistoryPage.fromJson(r.value?['value'] as Map<String, dynamic>?);
    setState(() {
      final existing = _messages.map((m) => m.seq).toSet();
      final older = page.messages.where((m) => !existing.contains(m.seq));
      _messages.insertAll(0, older);
      _hasMore = page.hasMore;
      _beforeSeq = page.beforeSeq;
    });
  }

  /* ---------------- 实时流 ---------------- */

  void _subscribe() {
    _liveSub = widget.live.connect().listen((frame) {
      if (!mounted) return;
      switch (frame) {
        case LiveHello(:final runningSessionIds):
          if (runningSessionIds.contains(widget.sessionId) && !_running) {
            setState(() => _running = true);
          }
        case LiveStatus(:final sessionId, :final running):
          // sessionId 为空的帧是「连接层状态」，不当成会话状态
          if (sessionId.isEmpty) return;
          if (sessionId != widget.sessionId) return;
          setState(() => _running = running);
          // 一轮结束时提问可能刚被 settle 或刚转成可补答 —— 顺手让面板对一次账
          if (!running) _bumpQuestions();
          // 注意：**不要**在这里 clear _streamBuf。
          // 宿主把 status:false 发得比 assistant/message 早一点点，
          // 先清就会把已经流出来的字擦掉，然后正式消息又还没到 ——
          // 界面上会闪一下空白。清理统一在 assistant/message 到达时做。
        case LiveEvent(:final sessionId, :final event):
          if (sessionId != widget.sessionId) return;
          final type = (event['type'] ?? '').toString();

          /*
           * 提问出现时立刻让面板去拉一次。
           *
           * ⚠️ 这个判断必须放在下面 `m == null → return` **之前**：
           * `tool/call` 不是消息事件，`ChatMessage.fromEvent` 对它返回 null，
           * 放到后面就永远走不到，面板只能等用户手动刷新。
           *
           * 只认 `ask_user_question` 这一个名字 —— 每个工具调用都去拉一次
           * 会在这条 0.86 MB/s 的上行上白费请求。
           * 「open → continued」那一跳不在这里管（那需要 tool/result，
           * 而 tool/result 太频繁），交给面板自己的 5 秒轮询。
           */
          if (type == 'tool/call') {
            final data = event['data'];
            final name = (data is Map) ? (data['name'] ?? '').toString() : '';
            if (name == 'ask_user_question') _bumpQuestions();
          }

          final m = ChatMessage.fromEvent(event);
          if (m == null) return;
          setState(() {
            /*
             * 只在 **assistant/message** 到达时清流式缓冲。
             *
             * user/message 到达时绝不能清 —— 那时 chunk 还没开始推，
             * 但它是「这一轮开始」的信号，清了也没内容可显示，
             * 更要紧的是别把上一轮残留的处理错了。
             */
            if (type == 'assistant/message') _streamBuf.clear();

            if (_messages.any((x) => x.seq == m.seq)) return;

            if (m.role == 'user') {
              /*
               * 用正式的 user/message 替换掉本地乐观插入的那条。
               *
               * ⚠️ 不要靠「文本相等」匹配 —— 阶段③实测过：本地存的是
               * 用户输入的原文，而宿主回显的内容可能带首尾空白/换行差异，
               * `x.text == m.text` 匹配不上，结果就是**同一条消息显示两遍**。
               *
               * 改成「找最后一条还没确认的本地用户消息」：一轮只会插一条，
               * 取最后一条准没错。
               */
              var idx = -1;
              for (var i = _messages.length - 1; i >= 0; i--) {
                final x = _messages[i];
                if (x.local && x.role == 'user') {
                  idx = i;
                  break;
                }
              }
              if (idx >= 0) {
                _messages[idx] = m;
                _messages.sort((a, b) => a.seq.compareTo(b.seq));
                return;
              }
            }

            _messages.add(m);
            _messages.sort((a, b) => a.seq.compareTo(b.seq));
          });
          if (_stickToBottom) _scrollToBottom();
        case LiveChunk(:final sessionId, :final chunk):
          if (sessionId != widget.sessionId) return;
          setState(() {
            _streamBuf.write(chunk);
            _running = true;
          });
          if (_stickToBottom) _scrollToBottom();
        case LivePing():
          break;
      }
    });
  }

  /* ---------------- 发送 ---------------- */

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;

    setState(() => _sending = true);
    _input.clear();

    /*
     * ⚠️ 这一层的契约是**插件 HTTP 接口**，不是宿主内部契约。
     *
     * 两者不一样，我在这里踩过一次（阶段③）：
     *
     *   宿主内部 sessionController.prompt 要的是
     *     { requestId, sessionId, mode, content: [{type:'text', text}] }
     *
     *   但插件的 /rw/api/session.prompt **要的是 `text` 字段**，
     *   `content` 由插件自己组装（见 host lib/session.js 的 prompt 实现）。
     *   照宿主契约传 content 数组，插件会回：
     *     { ok:false, error:{ code:'invalid-input',
     *       message:'消息内容为空（需要 text / images / fileReceipts 之一）' } }
     *
     * 所以这里传：sessionId + text + mode（可选 images / fileReceipts）。
     */
    final r = await widget.api.api('session.prompt', {
      'sessionId': widget.sessionId,
      'text': text,
      'mode': 'queue',
    });

    if (!mounted) return;
    setState(() => _sending = false);

    if (!r.ok) {
      // 失败要把话还给用户，不能悄悄吞掉
      _input.text = text;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text('发送失败：${r.friendlyError}')));
      return;
    }

    /*
     * 成功：**本地立刻插入一条用户消息**（乐观插入）。
     *
     * 为什么不靠 SSE 的 event 帧回显：
     *   宿主把消息落盘成 user/message 需要时间，SSE 回来之前界面上
     *   什么都没有 —— 用户会觉得「点了发送但没反应」。
     *
     * 此时 seq 用一个「比现有都大」的临时值，正式事件到达时
     * 用 `_hasLocalEcho` 标记去重（见 LiveEvent 分支）。
     */
    setState(() {
      /*
       * 乐观插入的 seq 用**当前最大 seq + 0.5**，不要用时间戳。
       *
       * 用时间戳（毫秒级大数）会让它排到所有真实消息之后很远，
       * 而正式 user/message 的 seq 是宿主给的小整数 —— 两者一比，
       * 排序结果和去重判断都会乱。
       *
       * 取「现有最大 + 0.5」既保证排在末尾，又和真实 seq 同一个量级。
       */
      final maxSeq = _messages.isEmpty
          ? 0.0
          : _messages.map((m) => m.seq).reduce((a, b) => a > b ? a : b);
      _messages.add(ChatMessage(
        seq: maxSeq + 0.5,
        role: 'user',
        text: text,
        local: true,
      ));
      _stickToBottom = true;
      _running = true;
    });
    _scrollToBottom();
  }

  void _scrollToBottom({bool jump = false}) {
    /*
     * ⚠️ 必须 post frame，而且要**连着两帧**。
     *
     * `setState` 之后立刻读 `maxScrollExtent` 拿到的是旧值（踩坑文档 4.5）。
     * 但一帧还不够：列表刚 `insertAll` 完，第一帧只是重新布局、还没测量完
     * 新加进来的那些气泡 —— 此时 maxScrollExtent 还是旧的。
     *
     * 阶段③实测：只用一帧时，进对话页后滚到了旧位置，
     * 而内容比之前长得多，表现就是「整个列表空白一片」。
     */
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final target = _scroll.position.maxScrollExtent;
      if (jump) {
        _scroll.jumpTo(target);
      } else {
        _scroll.animateTo(
          target,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
      // 第二帧再校正一次：第一帧可能还没测量到新插入的内容
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scroll.hasClients) return;
        final t2 = _scroll.position.maxScrollExtent;
        if ((t2 - _scroll.position.pixels).abs() > 8) {
          _scroll.jumpTo(t2);
        }
      });
    });
  }

  /* ---------------- 渲染 ---------------- */

  /// 让提问面板重新拉一次。面板用 `refreshTick` 变化来判断，不做重复请求。
  void _bumpQuestions() {
    if (!mounted) return;
    setState(() => _questionsTick++);
  }

  @override
  Widget build(BuildContext context) {
    final c = DshColors.of(widget.dark);
    return Scaffold(
      // 透明 + Mica：对话页和列表页共用同一块背景，
      // 否则进去会看到一片死灰（阶段③实测：只给透明不给 Mica，
      // Scaffold 会用 Theme 的 surface 色，和列表页完全不是一个底）
      backgroundColor: Colors.transparent,
      // ⚠️ 必须关掉：交给 composer 自己加 viewInsets.bottom 让位。
      // 两个都做会让位两遍，键盘弹起时布局被压塌（输入框顶到最上方）。
      resizeToAvoidBottomInset: false,
      body: SizedBox.expand(
        child: MicaBackdrop(
          dark: widget.dark,
          child: SafeArea(
            bottom: false,
            child: Column(
              children: [
                _buildAppBar(c),
                Expanded(child: _buildList(c)),
                /*
                 * 提问面板夹在消息列表和输入框之间。
                 *
                 * 放在这里而不是塞进 ListView 尾部：它必须**始终可见**
                 * （agent 正阻塞等人回答，用户翻到上面去看历史时也应该看见），
                 * 而且塞进 builder 列表里的话，滚出屏幕被回收，
                 * 用户填了一半的输入会因为 `TextEditingController` 一并销毁而丢失。
                 */
                QuestionPanel(
                  api: widget.api,
                  sessionId: widget.sessionId,
                  dark: widget.dark,
                  refreshTick: _questionsTick,
                  onAnswered: () => _scrollToBottom(),
                ),
                _buildComposer(c),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAppBar(DshColors c) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 6, 12, 6),
      child: Row(
        children: [
          IconButton(
            icon: DshIcon(DshGlyph.back, size: 20, color: c.textPrimary),
            onPressed: () => Navigator.of(context).pop(),
            constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
            padding: const EdgeInsets.all(8),
          ),
          const SizedBox(width: 2),
          Expanded(
            child: Text(
              widget.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: c.textPrimary,
              ),
            ),
          ),
          if (_running)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: SizedBox(
                width: 13,
                height: 13,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: c.accent,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildList(DshColors c) {
    if (_loading) {
      return Center(child: CircularProgressIndicator(color: c.accent));
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: c.textSecondary, fontSize: 13),
              ),
              const SizedBox(height: 12),
              FilledButton(onPressed: _loadHistory, child: const Text('重试')),
            ],
          ),
        ),
      );
    }

    // 流式内容作为一个额外的尾部气泡
    final streamText = _streamBuf.toString();
    final showStream = streamText.isNotEmpty;
    final itemCount = _messages.length + (showStream ? 1 : 0) + (_hasMore ? 1 : 0);

    if (itemCount == 0) {
      return Center(
        child: Text(
          '这个会话还没有消息',
          style: TextStyle(color: c.textTertiary, fontSize: 12.5),
        ),
      );
    }

    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      itemCount: itemCount,
      itemBuilder: (context, i) {
        var idx = i;
        if (_hasMore) {
          if (idx == 0) {
            return Center(
              child: TextButton(
                onPressed: _loadEarlier,
                child: Text(
                  '加载更早',
                  style: TextStyle(fontSize: 12, color: c.accent),
                ),
              ),
            );
          }
          idx -= 1;
        }
        if (idx < _messages.length) {
          return _bubble(c, _messages[idx]);
        }
        // 最后一个：流式气泡
        return _bubble(
          c,
          ChatMessage(
            seq: double.infinity,
            role: 'assistant',
            text: streamText,
            streaming: true,
          ),
        );
      },
    );
  }

  Widget _bubble(DshColors c, ChatMessage m) {
    // 「已回答提问」的回执走另一套渲染：默认收起，一行摘要，点开才看详情。
    // 按普通气泡渲染的话，正文是一整段 `{"kind":"answer_to_pending_question"...}`
    // 的原始 JSON，一屏都放不下（桌面端也不是这么显示的）。
    if (m.isQuestionReply) return _replyBubble(c, m);
    // 宿主注入的环境上下文（指令 / 技能目录 / 运行时快照）同样收起：
    // 这些动辄几千字，铺开会把真正的对话挤没（桌面端默认不显示）。
    if (m.isContext) return _contextBubble(c, m);

    final isUser = m.role == 'user';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        mainAxisAlignment:
            isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Flexible(
            child: Container(
              constraints: BoxConstraints(
                // 气泡最宽不超过屏幕 82%，留出对侧留白，一眼能看出谁说的
                maxWidth: MediaQuery.sizeOf(context).width * 0.82,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                /*
                 * 气泡底色用**不透明**的卡片色，不用半透明白。
                 *
                 * Mica 背景本身带冷/暖渐变，半透明白气泡叠上去会被染成灰蓝，
                 * 且和背景明度接近、边界糊在一起（阶段③实测：0xB8FFFFFF
                 * 在 Mica 上几乎看不出气泡轮廓）。
                 *
                 * 用户消息用淡主色（和「新会话」行同款），
                 * 助手消息用实心卡片色 —— 两种一眼可分。
                 */
                color: isUser
                    ? (widget.dark
                        ? const Color(0x3D60A5FA)
                        : const Color(0x26005FB8))
                    : (widget.dark
                        ? const Color(0xFF161616)
                        : const Color(0xFFFFFFFF)),
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(10),
                  topRight: const Radius.circular(10),
                  bottomLeft: Radius.circular(isUser ? 10 : 2),
                  bottomRight: Radius.circular(isUser ? 2 : 10),
                ),
                border: Border.all(
                  color: isUser ? c.accent.withValues(alpha: 0.45) : c.stroke,
                  width: 1,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  /*
                   * 正文渲染：
                   *   助手消息 → **Markdown**（宿主返回的就是标准 Markdown：
                   *              `**粗体**`、行内代码、`## 标题`、表格）
                   *   用户消息 → 纯文本。用户打的多半是口语，把 `*` `_` `|`
                   *              当语法解析反而会吃掉字符（比如发一个 `2*3*4`
                   *              会变成斜体）。要等宽/形状的场合本来就少。
                   *
                   * 流式期间也走 Markdown：这样「生成中」的正文和落地后
                   * 长得一模一样，不会在 assistant/message 到达的瞬间重排一次。
                   */
                  if (isUser)
                    Text(
                      m.text,
                      style: TextStyle(
                        fontSize: 13.5,
                        height: 1.45,
                        color: c.textPrimary,
                      ),
                    )
                  else
                    DshMarkdown(m.text, c: c, bubble: true),
                  if (m.streaming) ...[
                    const SizedBox(height: 6),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 10,
                          height: 10,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.6,
                            color: c.accent,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '生成中',
                          style: TextStyle(
                            fontSize: 10.5,
                            color: c.textTertiary,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 「已回答提问」回执：默认收起的一行卡片。
  ///
  /// 为什么必须单独做：宿主把答复 steer 回来的那条 user/message，
  /// 正文是
  ///   {"kind":"answer_to_pending_question","tool":"ask_user_question",
  ///    "callId":"call_...","questions":[{"id","question","header",
  ///    "options":[...],"multiSelect"}...],"answers":[{"id","selected","custom"}]}
  /// 按普通气泡渲染就是**一屏原始 JSON**，还会把题目/选项/描述全部重复一遍。
  /// 桌面端是默认隐藏的，手机这边对齐：收起 → 一行摘要；点开 → 题→答两行。
  Widget _replyBubble(DshColors c, ChatMessage m) {
    final expanded = _expandedReplies.contains(m.seq);
    final reply = m.reply;
    final lines = reply?.lines ?? const <QuestionReplyLine>[];

    // 收起时的摘要：把这批回答压成一行，`火锅、饺子 · 2130`
    final summary = lines.isEmpty
        ? (reply?.raw != null ? '（原始内容）' : m.text)
        : lines.map((l) => l.answer).join(' · ');

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Flexible(
            child: Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.sizeOf(context).width * 0.86,
              ),
              decoration: BoxDecoration(
                color: c.cardSolid,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: c.stroke),
              ),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => setState(() {
                    if (!_expandedReplies.remove(m.seq)) {
                      _expandedReplies.add(m.seq);
                    }
                  }),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            DshIcon(DshGlyph.check, size: 13, color: c.success),
                            const SizedBox(width: 6),
                            Text(
                              '已回答 DSH 提问',
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: c.textSecondary,
                              ),
                            ),
                            if (lines.isNotEmpty) ...[
                              const SizedBox(width: 6),
                              Text(
                                '${lines.length} 题',
                                style: TextStyle(
                                  fontSize: 10.5,
                                  color: c.textTertiary,
                                ),
                              ),
                            ],
                            const SizedBox(width: 6),
                            Icon(
                              expanded
                                  ? Icons.expand_less
                                  : Icons.expand_more,
                              size: 16,
                              color: c.textTertiary,
                            ),
                          ],
                        ),
                        const SizedBox(height: 3),
                        /*
                         * 收起态也要给出「答了什么」—— 只写「已回答」等于什么都没说，
                         * 用户还得点开才知道自己（或手机）回了什么。
                         * 单行截断，不折行。
                         */
                        Text(
                          summary,
                          maxLines: expanded ? 6 : 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.4,
                            color: c.textPrimary,
                          ),
                        ),
                        if (expanded) ...[
                          const SizedBox(height: 7),
                          Divider(color: c.stroke, height: 1),
                          const SizedBox(height: 7),
                          if (lines.isEmpty)
                            // 解析失败（宿主格式变了）时兜底：给原文，
                            // 但要限高 + 内部滚动，别再把整屏占满
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxHeight: 160),
                              child: SingleChildScrollView(
                                child: Text(
                                  m.text,
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    height: 1.4,
                                    color: c.textTertiary,
                                  ),
                                ),
                              ),
                            )
                          else
                            for (var i = 0; i < lines.length; i++)
                              Padding(
                                padding: EdgeInsets.only(
                                  bottom: i == lines.length - 1 ? 0 : 6,
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${i + 1}. ${lines[i].question}',
                                      style: TextStyle(
                                        fontSize: 11.5,
                                        height: 1.35,
                                        color: c.textTertiary,
                                      ),
                                    ),
                                    const SizedBox(height: 1),
                                    Text(
                                      lines[i].answer,
                                      style: TextStyle(
                                        fontSize: 12.5,
                                        height: 1.35,
                                        fontWeight: FontWeight.w600,
                                        color: c.accent,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 宿主注入的环境上下文（AGENTS.md 指令 / 技能目录 / 运行时快照）。
  ///
  /// 实测长度：`agent-instructions` 6838 字、`skill-catalog` 5615 字、
  /// `runtime-context` 409 字。按普通气泡渲染就是**好几屏英文系统提示**，
  /// 把真正的对话挤得一点不剩（桌面端默认是不显示的）。
  ///
  /// 这里做成一行小卡片：`ℹ 技能目录 · 5615 字 ⌄` + 一句话摘要，
  /// 点开才看原文，且限高 260 + 内部滚动 —— 不允许再把整屏占满。
  Widget _contextBubble(DshColors c, ChatMessage m) {
    final expanded = _expandedReplies.contains(m.seq);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Flexible(
            child: Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.sizeOf(context).width * 0.86,
              ),
              decoration: BoxDecoration(
                color: c.cardBg,
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: c.stroke),
              ),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(9),
                  onTap: () => setState(() {
                    if (!_expandedReplies.remove(m.seq)) {
                      _expandedReplies.add(m.seq);
                    }
                  }),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            DshIcon(
                              DshGlyph.info,
                              size: 12,
                              color: c.textTertiary,
                            ),
                            const SizedBox(width: 5),
                            Flexible(
                              child: Text(
                                m.contextLabel ?? '注入的上下文',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w600,
                                  color: c.textSecondary,
                                ),
                              ),
                            ),
                            const SizedBox(width: 5),
                            Text(
                              '${m.text.length} 字',
                              style: TextStyle(
                                fontSize: 10,
                                color: c.textTertiary,
                              ),
                            ),
                            Icon(
                              expanded
                                  ? Icons.expand_less
                                  : Icons.expand_more,
                              size: 15,
                              color: c.textTertiary,
                            ),
                          ],
                        ),
                        if (!expanded) ...[
                          const SizedBox(height: 2),
                          Text(
                            _firstMeaningfulLine(m.text),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: c.textTertiary,
                            ),
                          ),
                        ] else ...[
                          const SizedBox(height: 6),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 260),
                            child: SingleChildScrollView(
                              child: Text(
                                m.text,
                                style: TextStyle(
                                  fontSize: 10.5,
                                  height: 1.45,
                                  color: c.textTertiary,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 摘要行：跳过 `</system-reminder>` 这类标签行，取第一句人话。
  static String _firstMeaningfulLine(String text) {
    for (final line in text.split('\n')) {
      final t = line.trim();
      if (t.isEmpty || t.startsWith('<')) continue;
      return t;
    }
    return '（无摘要，点开查看）';
  }

  Widget _buildComposer(DshColors c) {
    return Container(
      /*
       * 键盘避让 —— 阶段③连踩两次，最终方案：
       *
       *  1. **外层 Scaffold 必须 `resizeToAvoidBottomInset: false`。**
       *     默认 true 时 Scaffold 自己会把 body 缩短一个键盘高度；
       *     如果 composer 里**又**加 `viewInsets.bottom`，等于让了两遍，
       *     布局被压到极致 —— 实测表现就是「输入框被顶到屏幕最上方、
       *     消息列表整块消失」。
       *
       *  2. 既然关掉了 Scaffold 的自动缩放，让位就**只在这一处**做：
       *     composer 底部 padding 加 `viewInsets.bottom`。
       *
       *  3. body 里的 SafeArea 用 `bottom: false`，底部 inset 不重复算。
       */
      padding: EdgeInsets.fromLTRB(
        12,
        8,
        12,
        8 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      decoration: BoxDecoration(
        color: c.winBg.withValues(alpha: 0.94),
        border: Border(top: BorderSide(color: c.stroke, width: 1)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: _input,
              minLines: 1,
              maxLines: 5,
              style: TextStyle(fontSize: 13.5, color: c.textPrimary),
              decoration: InputDecoration(
                hintText: '输入消息',
                hintStyle: TextStyle(fontSize: 13.5, color: c.textTertiary),
                filled: true,
                fillColor: c.inputFill,
                isDense: true,
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
              onSubmitted: (_) => _send(),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            height: 42,
            child: FilledButton(
              onPressed: _sending ? null : _send,
              style: FilledButton.styleFrom(
                backgroundColor: c.accent,
                foregroundColor: c.onAccent,
                padding: const EdgeInsets.symmetric(horizontal: 18),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: _sending
                  ? SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: c.onAccent,
                      ),
                    )
                  : const Text('发送'),
            ),
          ),
        ],
      ),
    );
  }
}




