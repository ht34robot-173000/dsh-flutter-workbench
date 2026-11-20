/// DSH 工作台 —— 会话历史与实时流的**数据层**。
///
/// 对应宿主：
///   POST /rw/api/session.history   {sessionId, maxMessages?, beforeSeq?}
///   GET  /rw/api/session.live       SSE
///
/// ⚠️ **两种消息结构不一样**（交接文档第五节「坑 1」，踩过很久）：
///
///   user/message      —— data 本身就是消息，**没有 message 这一层**
///     { type: "user/message", seq: 9,
///       data: { content: [...], source: {...}, role: "user", id: "..." } }
///
///   assistant/message —— data 里有 message 这一层
///     { type: "assistant/message",
///       data: { message: { content: [...] }, turn: 1, step: 1 } }
///
/// 写 `data.message` 对 user/message **永远拿到 null**，
/// 结果就是「用户自己的提问一条都不显示」——而且界面上看着还有对话，
/// 只是全是助手说的，极难发现。所以这里必须 `data.message ?? data`。
library;

import 'dart:convert';

/// 「已回答提问」的结构化内容。
///
/// 手机答完一道 `ask_user_question` 后，宿主会把答复作为一条 `user/message`
/// steer 回 agent，`source.kind === 'user-question-reply'`，正文是一坨 JSON：
///
///   {"kind":"answer_to_pending_question","tool":"ask_user_question",
///    "callId":"call_...",
///    "questions":[{"id":"dinner","question":"今晚吃什么？","options":[...]}],
///    "answers":[{"id":"dinner","selected":["火锅","饺子"]},
///               {"id":"when","selected":[],"custom":"2130"}]}
///
/// 直接把它当普通气泡渲染，就是**一整屏的原始 JSON**（而且里面把题目、
/// 选项、描述全重复了一遍）。桌面端不这么显示 —— 它是默认收起的。
/// 所以这里解析成「题 → 答」两行，界面上只显示摘要。
class QuestionReply {
  /// 每题一行：题干 + 最终答案（选项或自定义输入）。
  final List<QuestionReplyLine> lines;

  /// 没能解析成结构化内容时（宿主格式变了），至少保留原文供展开查看。
  final String? raw;

  const QuestionReply({this.lines = const [], this.raw});

  bool get isEmpty => lines.isEmpty;

  /// 从答复正文里解析。不是这类消息 / 解析失败都返回 null。
  static QuestionReply? tryParse(String text) {
    final trimmed = text.trim();
    if (!trimmed.startsWith('{')) return null;
    Map<String, dynamic> j;
    try {
      final d = jsonDecode(trimmed);
      if (d is! Map) return null;
      j = d.cast<String, dynamic>();
    } catch (_) {
      return null;
    }
    if ((j['kind'] ?? '').toString() != 'answer_to_pending_question') return null;

    // id → 题干（题目这边才有 question 文案，answer 那边只有 id）
    final stems = <String, String>{};
    final multi = <String, bool>{};
    final qs = j['questions'];
    if (qs is List) {
      for (final q in qs) {
        if (q is! Map) continue;
        final id = (q['id'] ?? '').toString();
        if (id.isEmpty) continue;
        stems[id] = (q['question'] ?? id).toString();
        multi[id] = q['multiSelect'] == true || q['multi_select'] == true;
      }
    }

    final lines = <QuestionReplyLine>[];
    final answers = j['answers'];
    if (answers is List) {
      for (final a in answers) {
        if (a is! Map) continue;
        final id = (a['id'] ?? '').toString();
        if (id.isEmpty) continue;
        final sel = <String>[];
        final rawSel = a['selected'];
        if (rawSel is List) {
          for (final s in rawSel) {
            if (s is String && s.isNotEmpty) sel.add(s);
          }
        }
        final custom = (a['custom'] ?? '').toString();
        lines.add(QuestionReplyLine(
          question: stems[id] ?? id,
          selected: sel,
          custom: custom.isEmpty ? null : custom,
        ));
      }
    }

    // 有 answers 但题目文案拿不到（stems 为空）时也能显示，只是退化成 id
    if (lines.isEmpty) return QuestionReply(raw: trimmed);
    return QuestionReply(
      lines: lines,
      // 保留原文：展开时可以看一眼宿主到底收到了什么
      raw: trimmed,
    );
  }
}

class QuestionReplyLine {
  final String question;
  final List<String> selected;
  final String? custom;

  const QuestionReplyLine({
    required this.question,
    this.selected = const [],
    this.custom,
  });

  /// 一句话答案：
  ///   单选 + 自定义 → 只显示自定义（custom 覆盖选项，此时 selected 为空）
  ///   多选 + 自定义 → `火锅、饺子（补充：带上朋友）`
  ///   什么都没答 → `（跳过）`
  String get answer {
    final c = custom;
    if (c != null && c.isNotEmpty) {
      if (selected.isEmpty) return c;
      return '${selected.join('、')}（补充：$c）';
    }
    if (selected.isNotEmpty) return selected.join('、');
    return '（跳过）';
  }
}

/// 一条可显示的消息。
class ChatMessage {
  /// 服务端事件序号。用于排序、去重、以及「加载更早」的游标。
  final double seq;

  /// 'user' | 'assistant'
  final String role;

  final String text;

  /// 消息里的图片（base64，不含 `data:` 前缀）。发送时本地乐观插入的图走这里。
  final List<String> images;

  /// 历史里的图片**只有引用，没有字节**：
  ///   `{"type":"image","attachment":{"attachmentId":"sha256:…","mediaType":"image/png","width":…,"height":…,"bytes":…}}`
  /// 要出缩略图必须回头调 `session.image`（宿主用 attachments.readImage 校验后回 base64）。
  /// 这里只存引用，真正的取字节交给界面上的 `_BubbleImage` 组件按需拉。
  final List<Map<String, dynamic>> imageRefs;

  /// 正在流式生成中（由 chunk 帧驱动）。
  final bool streaming;

  /// 工具调用摘要（只用于在气泡里附一行灰字，不做展开）。
  final List<String> toolNames;

  /// 本地乐观插入的消息（还没被宿主落盘回显）。
  ///
  /// 目的：点发送后立刻能在界面上看到自己发的那条，
  /// 不用等 SSE 的 user/message 事件回来。等正式事件到了再按内容去重。
  final bool local;

  /// 这条消息是「回答提问」的回执（`source.kind === 'user-question-reply'`）。
  ///
  /// 这种消息**不能按普通气泡渲染**：正文是整段 JSON（题目、选项、
  /// 描述全都重复一遍），一屏放不下。界面改成默认收起的一行摘要。
  final bool isQuestionReply;

  /// 解析出来的题/答对。解析失败时为 null（仍按收起卡片显示，展开见原文）。
  final QuestionReply? reply;

  /// 这条消息的 `source.kind`。**决定它是不是「人说的话」**：
  ///
  ///   user                  → 用户真的打的字
  ///   user-question-reply   → 手机/桌面答完提问后 steer 回来的回执（正文是 JSON）
  ///   agent-instructions    → AGENTS.md 指令（实测一整块 6838 字）
  ///   skill-catalog         → 技能目录（5615 字）
  ///   runtime-context       → 运行时上下文快照
  ///
  /// 后三种是**宿主注入的环境上下文**，桌面端默认不展示成气泡。
  /// 按普通气泡渲染的表现就是「一屏全是英文系统提示」，把真正的对话挤没了。
  final String? sourceKind;

  /// 是否是宿主注入的上下文（不是人说的话）。
  ///
  /// 只认已知的几种：**未知 kind 一律当普通消息显示**。
  /// 宁可多显示一条，也不要把用户真的打的字藏起来。
  bool get isContext => _contextKinds.contains(sourceKind);

  static const _contextKinds = {
    'agent-instructions',
    'runtime-context',
    'skill-catalog',
    'skill-content',
  };

  /// 上下文卡片上的名字。
  String? get contextLabel => switch (sourceKind) {
        'agent-instructions' => 'AGENTS.md / 项目指令',
        'runtime-context' => '运行时上下文',
        'skill-catalog' => '技能目录',
        'skill-content' => '技能内容',
        _ => null,
      };

  const ChatMessage({
    required this.seq,
    required this.role,
    required this.text,
    this.images = const [],
    this.imageRefs = const [],
    this.streaming = false,
    this.toolNames = const [],
    this.local = false,
    this.isQuestionReply = false,
    this.reply,
    this.sourceKind,
  });

  ChatMessage copyWith({
    double? seq,
    String? text,
    List<String>? images,
    List<Map<String, dynamic>>? imageRefs,
    bool? streaming,
    List<String>? toolNames,
    bool? local,
  }) =>
      ChatMessage(
        seq: seq ?? this.seq,
        role: role,
        text: text ?? this.text,
      images: images ?? this.images,
      imageRefs: imageRefs ?? this.imageRefs,
        streaming: streaming ?? this.streaming,
        toolNames: toolNames ?? this.toolNames,
        local: local ?? this.local,
        isQuestionReply: isQuestionReply,
        reply: reply,
        sourceKind: sourceKind,
      );

  /// 从一条 session 事件里抠出消息。不是消息类事件就返回 null。
  ///
  /// 这里刻意只认 user/message 和 assistant/message 两种 ——
  /// turn/start、step/end、tool/call 这些不进气泡（会刷屏），
  /// 但 tool/call 的**名字**会挂到同轮的助手气泡上作为一行摘要。
  static ChatMessage? fromEvent(Map<String, dynamic> ev) {
    final type = (ev['type'] ?? '').toString();
    if (type != 'user/message' && type != 'assistant/message') return null;

    final data = ev['data'];
    if (data is! Map) return null;

    // ⚠️ 关键：user/message 没有 message 这层，必须 `?? data`
    final msg = (data['message'] is Map) ? data['message'] as Map : data;

    final content = msg['content'];
    final buf = StringBuffer();
    final images = <String>[];
    final imageRefs = <Map<String, dynamic>>[];
    if (content is List) {
      for (final block in content) {
        if (block is! Map) continue;
        switch ((block['type'] ?? '').toString()) {
          case 'text':
            buf.write((block['text'] ?? '').toString());
            break;
          case 'image':
            // 三种情况：带 data（少见）、带 attachment 引用（历史的常态）、啥也没有
            final d = block['data'];
            final ref = block['attachment'];
            if (d is String && d.isNotEmpty) {
              images.add(d);
            } else if (ref is Map && (ref['attachmentId'] ?? '').toString().isNotEmpty) {
              imageRefs.add(ref.cast<String, dynamic>());
            } else {
              buf.write('[图片]');
            }
            break;
          case 'file':
            buf.write('[文件]');
            break;
        }
      }
    }

    final text = buf.toString();
    // 纯图片消息（不带文字）也要保留，否则自己发的照片在界面上根本不存在
    if (text.trim().isEmpty && images.isEmpty && imageRefs.isEmpty) return null;

    final seqRaw = ev['seq'];
    final seq = (seqRaw is num) ? seqRaw.toDouble() : 0.0;

    /*
     * 「回答提问」的回执要单独标出来。
     *
     * 它是一条正常的 user/message，正文却是整段 JSON
     * （`{"kind":"answer_to_pending_question", ...}`）。按普通气泡渲染
     * 就是一屏原始 JSON —— 桌面端不是这么显示的，默认是收起的。
     * 这里只做识别 + 解析，怎么显示交给界面的 `_replyBubble`。
     */
    final src = msg['source'];
    final srcKind = (src is Map) ? (src['kind'] ?? '').toString() : '';

    return ChatMessage(
      seq: seq,
      role: type == 'user/message' ? 'user' : 'assistant',
      text: text,
      images: images,
      imageRefs: imageRefs,
      isQuestionReply: srcKind == 'user-question-reply',
      reply: srcKind == 'user-question-reply' ? QuestionReply.tryParse(text) : null,
      sourceKind: srcKind.isEmpty ? null : srcKind,
    );
  }
}

/// 历史拉取的返回。
class HistoryPage {
  final List<ChatMessage> messages;

  final bool hasMore;
  final double? beforeSeq;
  final int totalCount;

  const HistoryPage({
    required this.messages,
    required this.hasMore,
    this.beforeSeq,
    this.totalCount = 0,
  });

  factory HistoryPage.fromJson(Map<String, dynamic>? value) {
    final events = value?['events'];
    final msgs = <ChatMessage>[];

    if (events is List) {
      for (final e in events) {
        if (e is! Map) continue;
        final m = ChatMessage.fromEvent(e.cast<String, dynamic>());
        if (m != null) msgs.add(m);
      }
    }
    msgs.sort((a, b) => a.seq.compareTo(b.seq));

    final bs = value?['beforeSeq'];
    return HistoryPage(
      messages: msgs,
      hasMore: value?['hasMore'] == true,
      beforeSeq: bs is num ? bs.toDouble() : null,
      totalCount: (value?['totalCount'] is num)
          ? (value!['totalCount'] as num).toInt()
          : 0,
    );
  }
}

/// SSE 帧。
sealed class LiveFrame {
  const LiveFrame();
}

/// 连接建立时的全量快照：哪些会话在跑。
class LiveHello extends LiveFrame {
  final List<String> runningSessionIds;
  const LiveHello(this.runningSessionIds);
}

/// agent 状态变化。
class LiveStatus extends LiveFrame {
  final String sessionId;
  final bool running;
  const LiveStatus(this.sessionId, this.running);
}

/// 一条完整 session 事件（消息在这里到达）。
class LiveEvent extends LiveFrame {
  final String sessionId;
  final Map<String, dynamic> event;
  const LiveEvent(this.sessionId, this.event);
}

/// 逐字增量。
class LiveChunk extends LiveFrame {
  final String sessionId;
  final String chunk;
  final int turn;
  final int step;
  const LiveChunk({
    required this.sessionId,
    required this.chunk,
    required this.turn,
    required this.step,
  });
}

/// 保活帧。收到后什么都不用做，但**不能当成未知帧丢掉连接**。
class LivePing extends LiveFrame {
  const LivePing();
}

/// 把一行 SSE data 解析成帧。解析不了返回 null（不抛）。
LiveFrame? parseLiveFrame(String data) {
  final trimmed = data.trim();
  if (trimmed.isEmpty) return null;

  Map<String, dynamic> j;
  try {
    final d = jsonDecode(trimmed);
    if (d is! Map) return null;
    j = d.cast<String, dynamic>();
  } catch (_) {
    return null;
  }

  final type = (j['type'] ?? '').toString();
  switch (type) {
    case 'hello':
      /*
       * ⚠️ `sessions` 是**对象数组**，不是字符串数组：
       *   {"type":"hello","sessions":[
       *      {"sessionId":"session-xxx","startedAt":1795078331622,"elapsedMs":31910}]}
       *
       * （2026-11-19 实测直连 SSE 确认。之前按 List<String> 解析，
       *  结果永远拿到空列表 —— 状态指示不亮）
       */
      final s = j['sessions'];
      final ids = <String>[];
      if (s is List) {
        for (final x in s) {
          if (x is String && x.isNotEmpty) {
            ids.add(x);
          } else if (x is Map) {
            final id = (x['sessionId'] ?? '').toString();
            if (id.isNotEmpty) ids.add(id);
          }
        }
      }
      return LiveHello(ids);
    case 'status':
      return LiveStatus(
        (j['sessionId'] ?? '').toString(),
        j['running'] == true,
      );
    case 'event':
      final ev = j['event'];
      if (ev is! Map) return null;
      return LiveEvent(
        (j['sessionId'] ?? '').toString(),
        ev.cast<String, dynamic>(),
      );
    case 'chunk':
      /*
       * ⚠️ `chunk` 是**对象**，不是字符串（2026-11-19 直连 SSE 实测）：
       *
       *   {"type":"chunk","sessionId":"...","seq":2587.0052,"turn":34,"step":1,
       *    "chunk":{"type":"text-delta","index":0,"text":"..."}}
       *
       * 早先写成 `(j['chunk'] ?? '').toString()` —— 那会把整个 Map
       * 变成 `{type: text-delta, index: 0, text: ...}` 这种 Dart 字符串，
       * 渲染出来是一串乱码，而不是正文。
       * 这是「流式显示不出来」的真正原因。
       *
       * 只认 `text-delta`：其余类型（reasoning-delta 之类）暂不进气泡，
       * 否则会把思考过程混进正文。
       */
      final ch = j['chunk'];
      String text = '';
      if (ch is String) {
        text = ch;
      } else if (ch is Map) {
        final kind = (ch['type'] ?? '').toString();
        if (kind == 'text-delta' || kind.isEmpty) {
          text = (ch['text'] ?? ch['delta'] ?? '').toString();
        }
      }
      if (text.isEmpty) return null;
      return LiveChunk(
        sessionId: (j['sessionId'] ?? '').toString(),
        chunk: text,
        turn: (j['turn'] is num) ? (j['turn'] as num).toInt() : 1,
        step: (j['step'] is num) ? (j['step'] as num).toInt() : 1,
      );
    case 'ping':
      return const LivePing();
    default:
      return null;
  }
}
