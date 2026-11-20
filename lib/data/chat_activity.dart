/// DSH 工作台 —— 对话里的「进行时」：工具调用行的数据模型。
///
/// 桌面端在一轮回答中间会插这种行：
///
/// ```
/// >_ 执行了命令并已写入文件
/// >_ 执行了命令，已读取文件，修改了文件
/// ⊗ 正在分析请求
/// ```
///
/// 数据来源是会话事件里的 `tool/call` + `tool/result`（历史里**没被裁掉**，
/// 宿主只对 tool/result 的超长文本做了截断，见 lib/session.js 的 trimEvent）：
///
/// ```jsonc
/// tool/call   { type, seq, data: { turn, step, callId, name, arguments } }   // arguments 是 JSON 字符串
/// tool/result { type, seq, data: { turn, step, message: { toolCallId, content:[{type:'text',text}], isError? },
///                                  error?: { code, name } } }
/// ```
///
/// 聚合口径：**按 (turn, step) 归一行**。桌面端就是「一个 step 一行，把这步用过的工具串起来说」，
/// 所以这里也这么做 —— 一个 step 里连开三条命令，不该在手机上一口气刷三行。
library;

/// 一次工具调用。
class ToolEntry {
  final String callId;
  final String name;

  /// 原始参数（JSON 字符串）。展示时尽量只挑一个关键字段，见 [argSummary]。
  final String arguments;

  /// 结果文本（可能为空 = 还没回来）。
  final String? result;

  /// 宿主报的错误（`tool/result` 里的 `error` 或 `message.isError`）。
  final String? error;

  const ToolEntry({
    required this.callId,
    required this.name,
    this.arguments = '',
    this.result,
    this.error,
  });

  bool get done => result != null || error != null;
  bool get failed => error != null;

  ToolEntry withResult(String? text, String? err) => ToolEntry(
        callId: callId,
        name: name,
        arguments: arguments,
        result: text,
        error: err,
      );

  /// 一句话说明这步干了什么：`执行了命令` / `读取了文件` …
  String get verb => toolVerb(name);

  /// 展开时显示的参数摘要。
  ///
  /// 为什么不整段 JSON 摊开：`pwsh` 的 arguments 里 command 才是人想看的，
  /// 其余字段（`timeout`、`cwd`…）只会把内容撑长。挑不出来才退回原文。
  String get argSummary {
    final raw = arguments.trim();
    if (raw.isEmpty) return '';
    for (final key in const ['command', 'path', 'file_path', 'pattern', 'query', 'url', 'text']) {
      final v = _pickJsonField(raw, key);
      if (v != null && v.trim().isNotEmpty) return v.trim();
    }
    return raw;
  }

  /// 从 JSON 字符串里糙取一个字段的值（不引 json 解析器，坏 JSON 也不抛）。
  static String? _pickJsonField(String raw, String key) {
    final marker = '"$key"';
    final i = raw.indexOf(marker);
    if (i < 0) return null;
    var j = raw.indexOf(':', i + marker.length);
    if (j < 0) return null;
    j += 1;
    while (j < raw.length && raw[j] == ' ') {
      j += 1;
    }
    if (j >= raw.length) return null;
    if (raw[j] == '"') {
      final buf = StringBuffer();
      var k = j + 1;
      while (k < raw.length) {
        final ch = raw[k];
        if (ch == r'\' && k + 1 < raw.length) {
          final nxt = raw[k + 1];
          // 只还原最常见的几个转义，够展示用
          buf.write(nxt == 'n' ? '\n' : (nxt == 't' ? '\t' : nxt));
          k += 2;
          continue;
        }
        if (ch == '"') break;
        buf.write(ch);
        k += 1;
      }
      return buf.toString();
    }
    // 非字符串值：读到逗号 / 右括号为止
    var k = j;
    while (k < raw.length && raw[k] != ',' && raw[k] != '}') {
      k += 1;
    }
    return raw.substring(j, k).trim();
  }
}

/// 一个 step 里的全部工具调用（展示成一行）。
class ChatActivity {
  final int turn;
  final int step;

  /// 这行在消息列表里的排序依据（这一 step 的第一个事件 seq）。
  final double seq;

  final List<ToolEntry> entries;

  const ChatActivity({
    required this.turn,
    required this.step,
    required this.seq,
    required this.entries,
  });

  String get key => '$turn:$step';

  /// 还有工具没回来 → 这步正在进行。
  bool get running => entries.any((e) => !e.done);

  bool get failed => entries.any((e) => e.failed);

  /// `执行了命令并已写入文件` 这种串。
  ///
  /// 同一个动词只出现一次（一个 step 里开了 5 条命令，不该说五遍「执行了命令」），
  /// 第一个用「并」连接还是用「、」，按出现顺序拼。
  String get summary {
    final verbs = <String>[];
    for (final e in entries) {
      if (!verbs.contains(e.verb)) verbs.add(e.verb);
    }
    if (verbs.isEmpty) return running ? '正在执行…' : '完成';
    if (verbs.length == 1) return verbs.first;
    return '${verbs.first}，${verbs.skip(1).join('，')}';
  }

  ChatActivity copyWithEntry(ToolEntry e) {
    final list = [...entries];
    final i = list.indexWhere((x) => x.callId == e.callId);
    if (i >= 0) {
      list[i] = e;
    } else {
      list.add(e);
    }
    return ChatActivity(turn: turn, step: step, seq: seq, entries: list);
  }
}

/// 工具名 → 中文动宾短语。桌面端那句「执行了命令并已写入文件」就是按这套说的。
String toolVerb(String name) {
  final n = name.toLowerCase();
  switch (n) {
    case 'pwsh':
    case 'shell':
    case 'bash':
    case 'exec':
    case 'process':
      return '执行了命令';
    case 'read':
    case 'view':
    case 'read_file':
      return '读取了文件';
    case 'write':
    case 'write_file':
    case 'create_file':
      return '写入了文件';
    case 'edit':
    case 'patch':
    case 'apply_patch':
    case 'str_replace':
      return '修改了文件';
    case 'grep':
    case 'search':
    case 'search_files':
      return '搜索了内容';
    case 'glob':
    case 'ls':
    case 'list':
    case 'list_dir':
      return '查找了文件';
    case 'web_search':
      return '联网搜索';
    case 'web_fetch':
    case 'fetch':
      return '抓取了网页';
    case 'todo_write':
    case 'todo':
      return '更新了待办';
    case 'ask_user_question':
      return '向你提问';
    case 'skill':
      return '加载了技能';
    case 'subagent':
    case 'workflow':
    case 'agent':
      return '派了子任务';
    case 'rea':
    default:
      return n.isEmpty ? '调用了工具' : '调用了 $name';
  }
}

/// 从一批事件里重建活动行（历史加载时用）。
///
/// 事件里 `tool/call` 和 `tool/result` 是按 seq 交替出现的，这里按 (turn, step)
/// 归并；结果靠 `toolCallId` 对回调用。
List<ChatActivity> buildActivities(Iterable<Map<String, dynamic>> events) {
  final map = <String, ChatActivity>{};
  final index = <String, String>{}; // callId → activity key

  for (final e in events) {
    final type = (e['type'] ?? '').toString();
    final data = e['data'];
    if (data is! Map) continue;
    final d = data.cast<String, dynamic>();
    final turn = d['turn'] is num ? (d['turn'] as num).toInt() : 0;
    final step = d['step'] is num ? (d['step'] as num).toInt() : 0;
    final key = '$turn:$step';
    final seqRaw = e['seq'];
    final seq = seqRaw is num ? seqRaw.toDouble() : 0.0;

    if (type == 'tool/call') {
      final callId = (d['callId'] ?? '').toString();
      if (callId.isEmpty) continue;
      final name = (d['name'] ?? 'tool').toString();
      final args = (d['arguments'] ?? '').toString();
      final cur = map[key] ??
          ChatActivity(turn: turn, step: step, seq: seq, entries: const []);
      map[key] = cur.copyWithEntry(
        ToolEntry(callId: callId, name: name, arguments: args),
      );
      index[callId] = key;
      continue;
    }

    if (type == 'tool/result') {
      final msg = d['message'];
      final callId = (msg is Map ? (msg['toolCallId'] ?? '') : '').toString();
      final key2 = index[callId];
      if (key2 == null) continue;
      final cur = map[key2];
      if (cur == null) continue;

      String? text;
      if (msg is Map && msg['content'] is List) {
        final buf = StringBuffer();
        for (final b in (msg['content'] as List)) {
          if (b is Map && (b['type'] ?? '') == 'text') {
            buf.write((b['text'] ?? '').toString());
          }
        }
        text = buf.isEmpty ? null : buf.toString();
      }
      final errRaw = d['error'];
      String? err;
      if (errRaw is Map) {
        err = (errRaw['code'] ?? errRaw['name'] ?? 'error').toString();
      } else if (msg is Map && msg['isError'] == true) {
        err = 'error';
      }

      final existing = cur.entries.firstWhere(
        (x) => x.callId == callId,
        orElse: () => ToolEntry(callId: callId, name: 'tool'),
      );
      map[key2] = cur.copyWithEntry(existing.withResult(text, err));
    }
  }

  final list = map.values.toList()..sort((a, b) => a.seq.compareTo(b.seq));
  return list;
}
