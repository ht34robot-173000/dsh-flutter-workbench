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

/// 一条可显示的消息。
class ChatMessage {
  /// 服务端事件序号。用于排序、去重、以及「加载更早」的游标。
  final double seq;

  /// 'user' | 'assistant'
  final String role;

  final String text;

  /// 正在流式生成中（由 chunk 帧驱动）。
  final bool streaming;

  /// 工具调用摘要（只用于在气泡里附一行灰字，不做展开）。
  final List<String> toolNames;

  /// 本地乐观插入的消息（还没被宿主落盘回显）。
  ///
  /// 目的：点发送后立刻能在界面上看到自己发的那条，
  /// 不用等 SSE 的 user/message 事件回来。等正式事件到了再按内容去重。
  final bool local;

  const ChatMessage({
    required this.seq,
    required this.role,
    required this.text,
    this.streaming = false,
    this.toolNames = const [],
    this.local = false,
  });

  ChatMessage copyWith({
    double? seq,
    String? text,
    bool? streaming,
    List<String>? toolNames,
    bool? local,
  }) =>
      ChatMessage(
        seq: seq ?? this.seq,
        role: role,
        text: text ?? this.text,
        streaming: streaming ?? this.streaming,
        toolNames: toolNames ?? this.toolNames,
        local: local ?? this.local,
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
    if (content is List) {
      for (final block in content) {
        if (block is! Map) continue;
        switch ((block['type'] ?? '').toString()) {
          case 'text':
            buf.write((block['text'] ?? '').toString());
            break;
          case 'image':
            buf.write('[图片]');
            break;
          case 'file':
            buf.write('[文件]');
            break;
        }
      }
    }

    final text = buf.toString();
    if (text.trim().isEmpty) return null;

    final seqRaw = ev['seq'];
    final seq = (seqRaw is num) ? seqRaw.toDouble() : 0.0;

    return ChatMessage(
      seq: seq,
      role: type == 'user/message' ? 'user' : 'assistant',
      text: text,
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
