// 「手机端回答 DSH 提问」的纯逻辑单测。
//
// 为什么值得写：这批逻辑有三处**静默失败**的坑（Kotlin 版全踩过）：
//   - `multi_select` 与 `multiSelect` 两种命名，只认一种 → 多选被当单选
//   - `options` 是对象数组不是字符串数组
//   - 提交时漏答一道题 → 宿主抛 BAD_ANSWER；单选带 custom 时不清空 selected
//     → custom 被选项覆盖，用户以为自己填的没生效
//
// 样本取自宿主投影的真实形状（dsh-user-questions/lib/types/projection.js）。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_workbench/data/chat_data.dart';
import 'package:dsh_workbench/data/questions_api.dart';

Map<String, dynamic> _j(String s) => jsonDecode(s) as Map<String, dynamic>;

void main() {
  group('AskQuestion.fromJson', () {
    test('投影形状：options 是对象数组，multiSelect 是 camelCase', () {
      final q = AskQuestion.fromJson(_j('''
        {
          "id": "dinner",
          "question": "今晚吃什么？",
          "header": "晚饭",
          "detail": "顺便定个时间",
          "multiSelect": true,
          "options": [
            {"label": "火锅", "description": "要等位"},
            {"label": "面条"}
          ]
        }
      '''));
      expect(q, isNotNull);
      expect(q!.id, 'dinner');
      expect(q.text, '今晚吃什么？');
      expect(q.header, '晚饭');
      expect(q.detail, '顺便定个时间');
      expect(q.multiSelect, isTrue);
      expect(q.options.map((o) => o.label), ['火锅', '面条']);
      expect(q.options.first.description, '要等位');
      expect(q.options.last.description, isNull);
    });

    test('模型侧 schema 是 multi_select（下划线），也必须认', () {
      // 只认 camelCase 的话，多选题会被当成单选 —— 用户只能选一个
      final q = AskQuestion.fromJson(_j('''
        {"id":"x","question":"选几个","multi_select":true,
         "options":[{"label":"A"},{"label":"B"}]}
      '''));
      expect(q!.multiSelect, isTrue);
    });

    test('缺 id 或题干就是无效题，返回 null（不要显示空白卡片）', () {
      expect(AskQuestion.fromJson(_j('{"question":"没 id"}')), isNull);
      expect(AskQuestion.fromJson(_j('{"id":"a"}')), isNull);
      expect(AskQuestion.fromJson(null), isNull);
      expect(AskQuestion.fromJson('字符串'), isNull);
    });

    test('options 偶尔是字符串数组：容错，别丢整道题', () {
      final q = AskQuestion.fromJson(_j('''
        {"id":"a","question":"选一个","options":["甲","乙"]}
      '''));
      expect(q!.options.map((o) => o.label), ['甲', '乙']);
    });
  });

  group('QuestionBatch / QuestionsView', () {
    test('active 批次带 state；questions 里的无效题被跳过', () {
      final v = QuestionsView.fromValue(_j('''
        {
          "sessionId": "session-x",
          "active": [
            {"callId": "call_1", "state": "continued",
             "questions": [
               {"id":"q1","question":"要不要继续？",
                "options":[{"label":"继续"},{"label":"停"}]},
               {"question":"这道题没 id，丢掉"}
             ]}
          ],
          "settled": [{"callId": "call_0", "answers": [{"id":"q","selected":["A"]}]}]
        }
      '''));
      expect(v.active, hasLength(1));
      expect(v.active.first.callId, 'call_1');
      expect(v.active.first.questions, hasLength(1));
      expect(v.active.first.answerable, isTrue);
      expect(v.settled, hasLength(1));
      expect(v.hasActive, isTrue);
    });

    test('open 状态不可提交（提交会被宿主静默吃掉）', () {
      final v = QuestionsView.fromValue(_j('''
        {"active":[{"callId":"c1","state":"open",
          "questions":[{"id":"q1","question":"确认？"}]}]}
      '''));
      expect(v.active.first.isOpen, isTrue);
      expect(v.active.first.answerable, isFalse);
      expect(v.hasBlocked, isTrue);
    });

    test('projection-unavailable 是「没问过」而不是错误：空列表 + reason', () {
      final v = QuestionsView.fromValue(_j(
          '{"sessionId":"s","active":[],"settled":[],"reason":"projection-unavailable"}'));
      expect(v.hasActive, isFalse);
      expect(v.reason, 'projection-unavailable');
    });

    test('坏数据不抛：value 为 null / active 不是数组', () {
      expect(QuestionsView.fromValue(null).hasActive, isFalse);
      expect(
        QuestionsView.fromValue(_j('{"active":"nope"}')).hasActive,
        isFalse,
      );
    });
  });

  group('QuestionDraft.toggle', () {
    test('单选：互斥，再点同一个就取消', () {
      var d = const QuestionDraft().toggle('A', multi: false);
      expect(d.selected, {'A'});
      d = d.toggle('B', multi: false);
      expect(d.selected, {'B'});
      d = d.toggle('B', multi: false);
      expect(d.selected, isEmpty);
    });

    test('多选：可以叠加，重复点取消', () {
      var d = const QuestionDraft().toggle('A', multi: true);
      d = d.toggle('B', multi: true);
      expect(d.selected, {'A', 'B'});
      d = d.toggle('A', multi: true);
      expect(d.selected, {'B'});
    });
  });

  group('QuestionReply（回答提问的回执）', () {
    // 真实样本：2026-11-20 在模拟器上从 App 提交后，宿主 steer 回来的正文
    const body = '{"kind":"answer_to_pending_question","tool":"ask_user_question",'
        '"callId":"call_00_ET_52Jja1zv0uGkvhNS4KEn5454",'
        '"questions":[{"id":"dinner","question":"今晚吃什么？","header":"晚饭",'
        '"options":[{"label":"火锅","description":"热闹，适合多人，准备时间较长。"}],'
        '"multiSelect":true},'
        '{"id":"when","question":"几点出发？","header":"时间",'
        '"options":[{"label":"19:00","description":"早一点"}],"multiSelect":false}],'
        '"answers":[{"id":"dinner","selected":["火锅","饺子"]},'
        '{"id":"when","selected":[],"custom":"2130"}]}';

    test('解析成「题 → 答」两行，而不是原样渲染 JSON', () {
      final r = QuestionReply.tryParse(body);
      expect(r, isNotNull);
      expect(r!.lines, hasLength(2));
      expect(r.lines[0].question, '今晚吃什么？');
      expect(r.lines[0].answer, '火锅、饺子');
      // 单选带 custom：custom 覆盖选项，selected 是空的
      expect(r.lines[1].question, '几点出发？');
      expect(r.lines[1].answer, '2130');
    });

    test('多选 + custom：两个都显示（custom 只是补充）', () {
      final r = QuestionReply.tryParse(
        '{"kind":"answer_to_pending_question","questions":[{"id":"q","question":"选"}],'
        '"answers":[{"id":"q","selected":["A","B"],"custom":"备注"}]}',
      );
      expect(r!.lines.single.answer, 'A、B（补充：备注）');
    });

    test('什么都没答的题显示「（跳过）」', () {
      final r = QuestionReply.tryParse(
        '{"kind":"answer_to_pending_question","questions":[{"id":"q","question":"选"}],'
        '"answers":[{"id":"q","selected":[]}]}',
      );
      expect(r!.lines.single.answer, '（跳过）');
    });

    test('不是这类消息 / 不是 JSON / kind 不对 → null（不误判普通消息）', () {
      expect(QuestionReply.tryParse('普通聊天内容'), isNull);
      expect(QuestionReply.tryParse('{ 坏 json'), isNull);
      expect(QuestionReply.tryParse('{"kind":"something-else","answers":[]}'), isNull);
    });

    test('kind 对但 answers 是空的 → 留原文，界面仍能收起显示', () {
      final r = QuestionReply.tryParse(
        '{"kind":"answer_to_pending_question","questions":[],"answers":[]}',
      );
      expect(r, isNotNull);
      expect(r!.lines, isEmpty);
      expect(r.raw, isNotNull);
    });

    test('ChatMessage.fromEvent 认得出 source.kind=user-question-reply', () {
      final ev = jsonDecode('{"type":"user/message","seq":42,'
          '"data":{"content":[{"type":"text","text":"${body.replaceAll('"', '\\"')}"}],'
          '"role":"user","id":"x",'
          '"source":{"kind":"user-question-reply","callId":"call_x","outcome":"answered"}}}')
          as Map<String, dynamic>;
      final m = ChatMessage.fromEvent(ev);
      expect(m, isNotNull);
      expect(m!.isQuestionReply, isTrue);
      expect(m.reply?.lines, hasLength(2));
      // 普通用户消息不能被误标
      final ev2 = jsonDecode('{"type":"user/message","seq":43,'
          '"data":{"content":[{"type":"text","text":"我也想说两句"}],'
          '"role":"user","id":"y","source":{"kind":"user"}}}') as Map<String, dynamic>;
      expect(ChatMessage.fromEvent(ev2)!.isQuestionReply, isFalse);
    });
  });

  group('注入的上下文（不该按普通气泡渲染）', () {
    ChatMessage msg(String kind) => ChatMessage.fromEvent(
          jsonDecode('{"type":"user/message","seq":5,"data":{'
              '"content":[{"type":"text","text":"<system-reminder>一大段系统提示</system-reminder>"}],'
              '"role":"user","id":"x","source":{"kind":"$kind"}}}') as Map<String, dynamic>,
        )!;

    test('三种注入 kind 都被识别，并给出中文标签', () {
      // 实测长度：agent-instructions 6838 字、skill-catalog 5615 字
      expect(msg('agent-instructions').isContext, isTrue);
      expect(msg('agent-instructions').contextLabel, 'AGENTS.md / 项目指令');
      expect(msg('skill-catalog').isContext, isTrue);
      expect(msg('skill-catalog').contextLabel, '技能目录');
      expect(msg('runtime-context').isContext, isTrue);
      expect(msg('runtime-context').contextLabel, '运行时上下文');
    });

    test('真正的用户消息不算上下文（不能把人说的话藏起来）', () {
      expect(msg('user').isContext, isFalse);
      expect(msg('user-question-reply').isContext, isFalse);
      // 未知 kind 一律当普通消息 —— 宁可多显示，不要误藏
      expect(msg('some-future-kind').isContext, isFalse);
    });
  });

  group('buildAnswers', () {
    AskQuestion q(String id, {bool multi = false, List<String> opts = const []}) =>
        AskQuestion(
          id: id,
          text: '题 $id',
          multiSelect: multi,
          options: [for (final o in opts) QuestionOption(o)],
        );

    test('单选：只带被选中的那个', () {
      final qs = [q('q1', opts: ['A', 'B'])];
      final out = buildAnswers(qs, {
        'q1': const QuestionDraft(selected: {'B'}),
      });
      expect(out, [
        {'id': 'q1', 'selected': ['B']},
      ]);
    });

    test('单选 + 自定义：custom 覆盖选项，selected 必须是空数组', () {
      // 宿主契约：单选时 custom 覆盖 selected。带着 selected 会导致
      // 「用户填的话被选项顶掉」，而界面上看不出来。
      final qs = [q('q1', opts: ['A', 'B'])];
      final out = buildAnswers(qs, {
        'q1': const QuestionDraft(selected: {'A'}, custom: '  我自己写的  '),
      });
      expect(out, [
        {'id': 'q1', 'selected': <String>[], 'custom': '我自己写的'},
      ]);
    });

    test('多选 + 自定义：两者都带上（custom 只是补充说明）', () {
      final qs = [q('q1', multi: true, opts: ['A', 'B', 'C'])];
      final out = buildAnswers(qs, {
        'q1': const QuestionDraft(selected: {'C', 'A'}, custom: '备注'),
      });
      // 顺序按题干，不按点击顺序 —— 同一组答案稳定可比
      expect(out, [
        {
          'id': 'q1',
          'selected': ['A', 'C'],
          'custom': '备注',
        },
      ]);
    });

    test('没答的题也要出现，selected 给空数组（跳过），否则整批 BAD_ANSWER', () {
      final qs = [q('q1', opts: ['A']), q('q2', opts: ['B'])];
      final out = buildAnswers(qs, {
        'q1': const QuestionDraft(selected: {'A'}),
      });
      expect(out, hasLength(2));
      expect(out[0]['id'], 'q1');
      expect(out[1], {'id': 'q2', 'selected': <String>[]});
    });

    test('选中项已经不在选项里（题目变了）→ 丢掉，不传脏值', () {
      final qs = [q('q1', multi: true, opts: ['A'])];
      final out = buildAnswers(qs, {
        'q1': const QuestionDraft(selected: {'A', '已过期'}),
      });
      expect(out.first['selected'], ['A']);
    });

    test('纯自由输入的题（没有 options）只能靠 custom', () {
      final qs = [q('q1')];
      final out = buildAnswers(qs, {
        'q1': const QuestionDraft(custom: '直接说'),
      });
      expect(out, [
        {'id': 'q1', 'selected': <String>[], 'custom': '直接说'},
      ]);
    });

    test('批次顺序与题干一致（多题不乱序）', () {
      final qs = [q('a', opts: ['1']), q('b', opts: ['2']), q('c', opts: ['3'])];
      final out = buildAnswers(qs, {
        'c': const QuestionDraft(selected: {'3'}),
        'a': const QuestionDraft(selected: {'1'}),
      });
      expect(out.map((e) => e['id']), ['a', 'b', 'c']);
    });
  });
}
