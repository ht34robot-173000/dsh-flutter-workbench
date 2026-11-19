/// DSH 工作台 —— 会话列表数据层。
///
/// 对应宿主 `/rw/api/session.list`，以及列表页需要的分组逻辑。
///
/// 三条从 Kotlin 版搬过来的规则（都是实测出来的，不能省）：
///
///  1. **标题取最后一个 `session/title`** —— 这条在宿主侧已经做掉了
///     （`lib/titles.js` 遍历多帧 zstd），所以 `session.list` 返回的
///     `title` 已经是最终值，这里不用再猜。
///
///  2. **归档状态不在 sessionController 里**，只存在
///     `workspaceRegistry.archivedSessionIds`。宿主已经把它合并进
///     `session.list` 的 `archived` 字段，这里直接用。
///
///  3. **分组按「工作区」**，组内排序是：置顶在前，其余按 updatedAt 倒序；
///     组之间按组内最新 updatedAt 倒序。空 workspace 的会话不进任何组。
library;

/// 一条会话。
class SessionItem {
  final String id;
  final String title;
  final int updatedAt;
  final bool archived;
  final String workspace;
  final bool isSubagent;
  final bool running;

  const SessionItem({
    required this.id,
    required this.title,
    required this.updatedAt,
    this.archived = false,
    this.workspace = '',
    this.isSubagent = false,
    this.running = false,
  });

  factory SessionItem.fromJson(Map<String, dynamic> j) => SessionItem(
        id: (j['id'] ?? '').toString(),
        // 空标题不要显示成空白卡 —— 统一叫「未命名会话」，
        // 和 Kotlin 版一致（那边是兜底文案，不是「无标题」）
        title: ((j['title'] ?? '') as String).trim().isEmpty
            ? '未命名会话'
            : (j['title'] as String).trim(),
        updatedAt: (j['updatedAt'] is num)
            ? (j['updatedAt'] as num).toInt()
            : int.tryParse('${j['updatedAt']}') ?? 0,
        archived: j['archived'] == true,
        workspace: (j['workspace'] ?? '').toString(),
        isSubagent: j['isSubagent'] == true,
        running: j['running'] == true,
      );
}

/// 一个工作区分组。
class SessionGroup {
  final String name;
  final List<SessionItem> items;
  const SessionGroup(this.name, this.items);

  int get count => items.length;
  int get latestAt =>
      items.fold<int>(0, (m, s) => s.updatedAt > m ? s.updatedAt : m);
}

class SessionListData {
  /// 全部会话（未过滤）。
  final List<SessionItem> all;

  const SessionListData(this.all);

  factory SessionListData.fromJson(List<dynamic> raw) => SessionListData(
        raw
            .whereType<Map<String, dynamic>>()
            .map(SessionItem.fromJson)
            .toList(),
      );

  /// 默认列表要显示的：非归档、非子智能体、且有归属工作区。
  List<SessionItem> get active => all
      .where((s) => !s.archived && !s.isSubagent && s.workspace.isNotEmpty)
      .toList();

  /// 分组。组内：置顶优先，再按 updatedAt 倒序；组间：按组内最新时间倒序。
  ///
  /// 顺序用 LinkedHashMap 保插入序 + 最后整体排序，和 Kotlin 版
  /// `SessionCache.grouped` 完全同一套逻辑，保证两边看到的顺序一样。
  List<SessionGroup> grouped(Set<String> pinned) {
    final buckets = <String, List<SessionItem>>{};
    for (final s in active) {
      buckets.putIfAbsent(s.workspace, () => []).add(s);
    }
    final groups = buckets.entries.map((e) {
      final items = [...e.value]..sort((a, b) {
          final pa = pinned.contains(a.id);
          final pb = pinned.contains(b.id);
          if (pa != pb) return pa ? -1 : 1;
          return b.updatedAt.compareTo(a.updatedAt);
        });
      return SessionGroup(e.key, items);
    }).toList();

    groups.sort((a, b) => b.latestAt.compareTo(a.latestAt));
    return groups;
  }

  /// 子智能体会话（设置里可开关）。
  List<SessionItem> get subagents =>
      all.where((s) => s.isSubagent && !s.archived).toList();

  /// 已归档。
  List<SessionItem> get archivedItems => all.where((s) => s.archived).toList();

  /// 没归属工作区的（工作区已解散/被删）。
  List<SessionItem> get ungrouped => all
      .where((s) => !s.archived && !s.isSubagent && s.workspace.isEmpty)
      .toList();
}

/// 时间格式化 —— **必须和 Kotlin 版逐字符一致**。
///
/// Kotlin 是 `SimpleDateFormat("MM-dd HH:mm")`，所以：
///   `11-19 05:18`
/// 不是「今天/昨天」，也不是相对时间。看着有点原始，但两个版本要能并排比对，
/// 时间格式不一致会让人以为是数据错了。
String formatSessionTime(int ms) {
  if (ms <= 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}
