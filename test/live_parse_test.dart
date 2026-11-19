// SSE 帧解析的单元测试。
//
// 为什么值得写：阶段③在「chunk 收不到」上耗了很久，最后发现是两个
// 独立的解析错误（`chunk` 是对象不是字符串、`hello.sessions` 是对象数组）。
// 这两处纯逻辑，用真人样本固定住，以后不会再退化。
//
// 样本全部来自 2026-11-19 直连宿主 SSE 的真实抓包。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_workbench/data/chat_data.dart';

void main() {
  group('parseLiveFrame', () {
    test('hello：sessions 是对象数组，不是字符串数组', () {
      // ⚠️ 真实帧长这样（早期按 List<String> 解析，永远拿到空列表）
      const raw = '{"type":"hello","sessions":['
          '{"sessionId":"session-3f2ac905-ff7e-480d-81a3-f902d41268a6",'
          '"startedAt":1795078331622,"elapsedMs":31910}]}';
      final f = parseLiveFrame(raw);
      expect(f, isA<LiveHello>());
      expect((f as LiveHello).runningSessionIds,
          ['session-3f2ac905-ff7e-480d-81a3-f902d41268a6']);
    });

    test('status：带 sessionId', () {
      const raw = '{"type":"status","sessionId":"session-abc","running":true,'
          '"startedAt":1795078428159,"elapsedMs":0}';
      final f = parseLiveFrame(raw);
      expect(f, isA<LiveStatus>());
      final s = f as LiveStatus;
      expect(s.sessionId, 'session-abc');
      expect(s.running, isTrue);
    });

    test('chunk：chunk 字段是对象，文本在 .text', () {
      // ⚠️ 这是「流式显示不出来」的真正根因。
      // 早期写 `(j['chunk'] ?? '').toString()`，会把整个 Map 转成
      // `{type: text-delta, index: 0, text: ...}` 这种字符串。
      const raw = '{"type":"chunk","sessionId":"session-abc",'
          '"seq":2587.0052,"turn":34,"step":1,'
          '"chunk":{"type":"text-delta","index":0,"text":"你好"}}';
      final f = parseLiveFrame(raw);
      expect(f, isA<LiveChunk>());
      final c = f as LiveChunk;
      expect(c.chunk, '你好');
      expect(c.turn, 34);
      expect(c.step, 1);
    });

    test('chunk：非 text-delta 类型被忽略（不把思考过程混进正文）', () {
      const raw = '{"type":"chunk","sessionId":"session-abc","turn":1,"step":1,'
          '"chunk":{"type":"reasoning-delta","index":0,"text":"思考中"}}';
      expect(parseLiveFrame(raw), isNull);
    });

    test('ping 帧', () {
      expect(parseLiveFrame('{"type":"ping"}'), isA<LivePing>());
    });

    test('坏 JSON 不抛异常', () {
      expect(parseLiveFrame('not json at all'), isNull);
      expect(parseLiveFrame(''), isNull);
    });
  });

  group('ChatMessage.fromEvent', () {
    test('user/message：data 本身就是消息（没有 message 层）', () {
      // 交接文档第五节「坑 1」。写 data.message 会永远拿到 null，
      // 结果就是「用户自己的提问一条都不显示」。
      final ev = jsonDecode('{"type":"user/message","seq":9,'
          '"data":{"content":[{"type":"text","text":"我发的话"}],'
          '"role":"user","id":"x"}}') as Map<String, dynamic>;
      final m = ChatMessage.fromEvent(ev);
      expect(m, isNotNull);
      expect(m!.role, 'user');
      expect(m.text, '我发的话');
      expect(m.seq, 9);
    });

    test('assistant/message：data 里有 message 这一层', () {
      final ev = jsonDecode('{"type":"assistant/message",'
          '"data":{"message":{"content":[{"type":"text","text":"助手的话"}]},'
          '"turn":1,"step":1}}') as Map<String, dynamic>;
      final m = ChatMessage.fromEvent(ev);
      expect(m, isNotNull);
      expect(m!.role, 'assistant');
      expect(m.text, '助手的话');
    });

    test('非消息事件返回 null', () {
      final ev = jsonDecode('{"type":"turn/start","data":{}}')
          as Map<String, dynamic>;
      expect(ChatMessage.fromEvent(ev), isNull);
    });
  });
}
