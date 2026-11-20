// 「进行时」行（工具调用摘要）的解析测试。
//
// 样本来自真实会话事件（宿主的 session.history 原样返回，tool/call 和
// tool/result 都没被裁）。固定三件事：
//   1. 一个 step 里的多个工具聚合成**一行**，动词去重；
//   2. tool/result 能按 toolCallId 对回调用，失败态要标出来；
//   3. 参数摘要优先取 command/path 这类关键字段，而不是整段 JSON。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_workbench/data/chat_activity.dart';

Map<String, dynamic> _j(String s) => jsonDecode(s) as Map<String, dynamic>;

Map<String, dynamic> _call(int turn, int step, String id, String name, String args, int seq) =>
    _j('{"type":"tool/call","seq":$seq,"data":{"turn":$turn,"step":$step,'
        '"callId":"$id","name":"$name","arguments":${jsonEncode(args)}}}');

Map<String, dynamic> _result(
  int turn,
  int step,
  String id,
  String text,
  int seq, {
  String? errorCode,
}) =>
    _j('{"type":"tool/result","seq":$seq,"data":{"turn":$turn,"step":$step,'
        '"message":{"toolCallId":"$id","content":[{"type":"text","text":${jsonEncode(text)}}]},'
        '${errorCode == null ? '' : '"error":{"code":"$errorCode"},'}'
        '"turn2":0}}');

void main() {
  group('toolVerb', () {
    test('常见工具都有中文说法', () {
      expect(toolVerb('pwsh'), '执行了命令');
      expect(toolVerb('read'), '读取了文件');
      expect(toolVerb('write'), '写入了文件');
      expect(toolVerb('edit'), '修改了文件');
      expect(toolVerb('grep'), '搜索了内容');
      expect(toolVerb('ask_user_question'), '向你提问');
    });

    test('未知工具兜底成「调用了 xxx」，不抛', () {
      expect(toolVerb('some_new_tool'), '调用了 some_new_tool');
      expect(toolVerb(''), '调用了工具');
    });
  });

  group('buildActivities', () {
    test('一个 step 里两个工具聚成一行，动词去重', () {
      final acts = buildActivities([
        _call(13, 1, 'c1', 'pwsh', '{"command":"ls"}', 100),
        _result(13, 1, 'c1', 'a.txt', 101),
        _call(13, 1, 'c2', 'write', '{"path":"F:\\\\x.txt"}', 102),
        _result(13, 1, 'c2', 'ok', 103),
      ]);
      expect(acts, hasLength(1));
      expect(acts.first.entries, hasLength(2));
      expect(acts.first.summary, '执行了命令，写入了文件');
      expect(acts.first.running, isFalse);
    });

    test('同一动词重复出现只算一次', () {
      final acts = buildActivities([
        _call(1, 1, 'a', 'pwsh', '{"command":"ls"}', 10),
        _call(1, 1, 'b', 'pwsh', '{"command":"pwd"}', 11),
      ]);
      expect(acts.first.summary, '执行了命令');
    });

    test('结果没回来的行是 running', () {
      final acts = buildActivities([
        _call(2, 2, 'c9', 'grep', '{"pattern":"TODO"}', 20),
      ]);
      expect(acts.first.running, isTrue);
      expect(acts.first.summary, '搜索了内容');
    });

    test('tool/result 带 error 时标记失败', () {
      final acts = buildActivities([
        _call(3, 1, 'c3', 'read', '{"path":"F:\\\\nope.txt"}', 30),
        _result(3, 1, 'c3', '', 31, errorCode: 'ENOENT'),
      ]);
      expect(acts.first.entries.first.failed, isTrue);
      expect(acts.first.entries.first.error, 'ENOENT');
      expect(acts.first.failed, isTrue);
    });

    test('不同 step 分成两行，按 seq 排序', () {
      final acts = buildActivities([
        _call(5, 2, 'b', 'pwsh', '{"command":"pwd"}', 52),
        _call(5, 1, 'a', 'read', '{"path":"F:\\\\a.md"}', 51),
      ]);
      expect(acts, hasLength(2));
      expect(acts[0].step, 1);
      expect(acts[1].step, 2);
      expect(acts[0].seq < acts[1].seq, isTrue);
    });

    test('没有 toolCallId 对不上的 result 被忽略，不抛', () {
      final acts = buildActivities([
        _call(1, 1, 'c1', 'pwsh', '{"command":"ls"}', 1),
        _result(1, 1, 'unknown-id', 'x', 2),
      ]);
      expect(acts.first.entries.first.done, isFalse);
    });
  });

  group('ToolEntry.argSummary', () {
    test('pwsh 取 command，而不是整段 JSON', () {
      const e = ToolEntry(
        callId: 'c',
        name: 'pwsh',
        arguments: '{"command": "cd F:\\\\a\\nls", "timeout": 30000}',
      );
      expect(e.argSummary, contains('cd F:'));
      expect(e.argSummary, isNot(contains('timeout')));
    });

    test('read 取 path', () {
      const e = ToolEntry(
        callId: 'c',
        name: 'read',
        arguments: '{"path":"F:\\\\插件\\\\AGENTS.md"}',
      );
      expect(e.argSummary, r'F:\插件\AGENTS.md');
    });

    test('挑不出关键字段就退回原文；空参数给空串', () {
      const e = ToolEntry(callId: 'c', name: 'x', arguments: '{"foo":1}');
      expect(e.argSummary, '{"foo":1}');
      expect(const ToolEntry(callId: 'c', name: 'x').argSummary, '');
    });

    test('坏 JSON 不抛（糙取字段）', () {
      const e = ToolEntry(callId: 'c', name: 'x', arguments: '{"command":"a\\"b"');
      expect(() => e.argSummary, returnsNormally);
    });
  });
}
