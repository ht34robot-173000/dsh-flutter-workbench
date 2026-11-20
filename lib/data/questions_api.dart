/// DSH 工作台 —— 「手机端回答 DSH 提问」数据层。
///
/// 对应宿主两个接口（`host-plugin-dsh-remote-workbench` 的 `lib/session.js`）：
///
///   POST /rw/api/session.questions  {sessionId}
///     → { active: [{callId, questions:[...], state}], settled: [{callId, answers}] }
///
///   POST /rw/api/session.answer     {sessionId, callId, answers:[{id, selected, custom?}]}
///     → { answered: bool }
///
/// ⚠️ 三条从 Kotlin 版实测继承下来的硬约束（写错就是「答了没反应」：
///    接口回 `ok:true, answered:false`，题目一直卡在 active）：
///
///   1. **`state` 必须看**：
///      `open`      —— 工具调用还挂着，只有 asker 那条原始 Promise 能回答。
///                     远端提交会被宿主**静默吃掉**。要等它超时转 `continued`。
///      `continued` —— 已超时，走 `userQuestions.answer()` 把答复 steer 进 agent。
///                     **这是手机端唯一可靠的路**（手机是慢速远端，等它反应过来
///                     时窗口多半已经关了，所以实际能答的时候占多数）。
///
///   2. **一个批次里每道题都要各答一次**，多答漏答都抛 `BAD_ANSWER`；
///      同一批次只能排一条回复，重复答抛 `REPLY_QUEUED`。
///      跳过某题要**显式**给 `{id, selected: []}`，不能省掉。
///
///   3. **单选的 `custom` 会覆盖选项**，此时 `selected` 必须留空数组；
///      多选的 `custom` 只是补充说明，`selected` 照常带。
///
/// 还有两个字段层面的坑：
///   - 多选标记在**模型侧 schema 是 `multi_select`（下划线）**，
///     而投影/Service 契约是 `multiSelect`（camelCase）。两种都要认，
///     只认一种会把多选当单选。
///   - `options` 是**对象数组** `[{label, description?}]`，不是字符串数组。
///     （早期按 `List<String>` 解析会拿到一堆空 label。）
library;

import 'ds_api.dart';

/// 一个候选项。
class QuestionOption {
  final String label;
  final String? description;

  const QuestionOption(this.label, [this.description]);

  @override
  String toString() => 'QuestionOption($label)';
}

/// 一道题。
class AskQuestion {
  final String id;

  /// 题干。宿主字段名是 `question`。
  final String text;

  /// 短标题（可选，界面上作为题目前的小标签）。
  final String? header;

  /// 补充说明。审核类提问（plan approve）会把要审的内容放这里。
  final String? detail;

  final List<QuestionOption> options;
  final bool multiSelect;

  const AskQuestion({
    required this.id,
    required this.text,
    this.header,
    this.detail,
    this.options = const [],
    this.multiSelect = false,
  });

  bool get hasOptions => options.isNotEmpty;

  /// 从宿主 JSON 里读一道题。只认认识的字段，缺的不猜。
  static AskQuestion? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final m = raw.cast<String, dynamic>();
    final id = (m['id'] ?? '').toString();
    final text = (m['question'] ?? '').toString();
    if (id.isEmpty || text.isEmpty) return null;

    final opts = <QuestionOption>[];
    final rawOpts = m['options'];
    if (rawOpts is List) {
      for (final o in rawOpts) {
        if (o is String) {
          // 容错：万一某处真的给的是字符串数组
          if (o.isNotEmpty) opts.add(QuestionOption(o));
        } else if (o is Map) {
          final label = (o['label'] ?? '').toString();
          if (label.isEmpty) continue;
          final desc = (o['description'] ?? '').toString();
          opts.add(QuestionOption(label, desc.isEmpty ? null : desc));
        }
      }
    }

    // ⚠️ 两种命名都要认（见文件头）
    final multi = m['multiSelect'] == true || m['multi_select'] == true;

    final header = (m['header'] ?? '').toString();
    final detail = (m['detail'] ?? '').toString();

    return AskQuestion(
      id: id,
      text: text,
      header: header.isEmpty ? null : header,
      detail: detail.isEmpty ? null : detail,
      options: opts,
      multiSelect: multi,
    );
  }
}

/// 一次提问（一个 `tool/call` = 一个批次）。
class QuestionBatch {
  final String callId;
  final List<AskQuestion> questions;

  /// `open` | `continued`
  final String state;

  const QuestionBatch({
    required this.callId,
    required this.questions,
    required this.state,
  });

  /// `settled[]` 的条目只有 callId + answers，没有题干 —— 用它建一个占位。
  const QuestionBatch.settledOnly(this.callId)
      : questions = const [],
        state = 'settled';

  bool get isOpen => state == 'open';

  /// 远端能不能现在提交。
  ///
  /// `open` 时提交会被宿主静默吃掉（`answered:false`），所以界面必须
  /// 明确拦住并提示「等它超时转可补答」，不能假装成功。
  bool get answerable => !isOpen;

  static QuestionBatch? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final m = raw.cast<String, dynamic>();
    final callId = (m['callId'] ?? '').toString();
    if (callId.isEmpty) return null;

    final qs = <AskQuestion>[];
    final rawQs = m['questions'];
    if (rawQs is List) {
      for (final q in rawQs) {
        final parsed = AskQuestion.fromJson(q);
        if (parsed != null) qs.add(parsed);
      }
    }
    if (qs.isEmpty) return null;

    final state = (m['state'] ?? '').toString();
    return QuestionBatch(
      callId: callId,
      questions: qs,
      // 缺 state 时按「可补答」处理：投影一定会给，这里只是别把整批丢掉。
      state: state.isEmpty ? 'continued' : state,
    );
  }
}

/// `session.questions` 的返回。
class QuestionsView {
  final List<QuestionBatch> active;
  final List<QuestionBatch> settled;

  /// 宿主读不到投影时会带回 `projection-unavailable`。
  /// 那**不是错误**（这个会话就是没问过问题），只是解释为什么是空的。
  final String? reason;

  const QuestionsView({
    this.active = const [],
    this.settled = const [],
    this.reason,
  });

  bool get hasActive => active.isNotEmpty;

  /// 有题在等，而且是「现在还答不了」的那种。
  bool get hasBlocked => active.any((b) => !b.answerable);

  factory QuestionsView.fromValue(Map<String, dynamic>? value) {
    final active = <QuestionBatch>[];
    final rawActive = value?['active'];
    if (rawActive is List) {
      for (final b in rawActive) {
        final parsed = QuestionBatch.fromJson(b);
        if (parsed != null) active.add(parsed);
      }
    }
    final settled = <QuestionBatch>[];
    final rawSettled = value?['settled'];
    if (rawSettled is List) {
      // settled 里没有 questions/state，只有 callId + answers。
      // 界面只需要「答完了」这个事实，所以这里不解析成 QuestionBatch 的题干。
      for (final s in rawSettled) {
        if (s is Map && (s['callId'] ?? '').toString().isNotEmpty) {
          settled.add(QuestionBatch.settledOnly(s['callId'].toString()));
        }
      }
    }
    return QuestionsView(
      active: active,
      settled: settled,
      reason: (value?['reason'] ?? '').toString().isEmpty
          ? null
          : value!['reason'].toString(),
    );
  }

  /// 答案本地草稿：选中的选项 label + 自定义输入。
  ///
  /// 单独一个类型是因为**提交时的规整规则**很容易写错（见 buildAnswers），
  /// 而那部分必须能被单元测试覆盖。
  static const empty = QuestionsView();
}

/// `settled[]` 只用来表示「已答过」，题干不需要。

/// 一道题的作答草稿。
class QuestionDraft {
  final Set<String> selected;
  final String custom;

  const QuestionDraft({this.selected = const {}, this.custom = ''});

  bool get isEmpty => selected.isEmpty && custom.trim().isEmpty;

  QuestionDraft copyWith({Set<String>? selected, String? custom}) =>
      QuestionDraft(
        selected: selected ?? this.selected,
        custom: custom ?? this.custom,
      );

  /// 单选：点同一个选项 = 取消。
  QuestionDraft toggle(String label, {required bool multi}) {
    final next = {...selected};
    if (multi) {
      if (!next.remove(label)) next.add(label);
    } else {
      final wasOn = next.contains(label);
      next.clear();
      if (!wasOn) next.add(label);
    }
    return copyWith(selected: next);
  }
}

/// 把界面上的草稿整理成宿主严格要求的 `answers` 数组。
///
/// 规则（对不上就抛 `BAD_ANSWER`，所以这里必须显式、确定）：
///
///   - **每道题都出现一次**，顺序与题干一致（宿主按 id 对应，但顺序一致最好排查）
///   - 单选 + 自定义输入 → `{id, selected: [], custom: "..."}`
///     （**`custom` 会覆盖选项**，所以 selected 必须清空）
///   - 多选 + 自定义输入 → `{id, selected: [...], custom: "..."}`
///     （多选时 custom 只是补充说明）
///   - 什么都没选没填 → `{id, selected: []}`，语义是「跳过这道题」
///   - 选项按**题干里的顺序**输出，不按用户点击顺序 —— 让同一组答案稳定可比
List<Map<String, dynamic>> buildAnswers(
  List<AskQuestion> questions,
  Map<String, QuestionDraft> drafts,
) {
  final out = <Map<String, dynamic>>[];
  for (final q in questions) {
    final draft = drafts[q.id] ?? const QuestionDraft();
    final custom = draft.custom.trim();

    // 按题干顺序挑出被选中的 label，顺带过滤掉已经不在选项里的（题目可能变了）
    final picked = <String>[];
    for (final o in q.options) {
      if (draft.selected.contains(o.label)) picked.add(o.label);
    }
    // 没有 options 的题（纯自由输入）也允许把用户输入当 selected 的情况：
    // 这类题不存在选项，只能靠 custom。
    if (q.multiSelect) {
      if (custom.isEmpty) {
        out.add({'id': q.id, 'selected': picked});
      } else {
        out.add({'id': q.id, 'selected': picked, 'custom': custom});
      }
    } else {
      if (custom.isNotEmpty) {
        // ⚠️ 单选：custom 覆盖选项，selected 必须留空
        out.add({'id': q.id, 'selected': const <String>[], 'custom': custom});
      } else {
        out.add({
          'id': q.id,
          'selected': picked.isEmpty ? const <String>[] : [picked.first],
        });
      }
    }
  }
  return out;
}

/// 接口封装。挂在 `DshApi` 上用，不自己管 baseUrl / cookie。
class QuestionsApi {
  final DshApi api;
  QuestionsApi(this.api);

  Future<ApiResult> fetch(String sessionId) =>
      api.api('session.questions', {'sessionId': sessionId});

  Future<ApiResult> answer({
    required String sessionId,
    required String callId,
    required List<Map<String, dynamic>> answers,
  }) =>
      api.api('session.answer', {
        'sessionId': sessionId,
        'callId': callId,
        'answers': answers,
      });
}
