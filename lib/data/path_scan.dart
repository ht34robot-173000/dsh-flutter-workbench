/// DSH 工作台 —— 从对话正文里认出「真实可达的路径」。
///
/// 需求：助手经常在正文里甩一串路径（`F:\插件\dsh-mobile\01-文档\xxx.md`、
/// `` `F:\dsh-flutter\lib\ui\chat_page.dart` ``），手机上干瞪眼 —— 看得到点不了。
/// 这里负责把它们抠出来，交给界面做成可点条目，点击直接用**远控的资源管理器**
/// 打开（`fs.list` + `FileBrowserPage`），不需要在手机上另接文件选择器。
///
/// 几个刻意的取舍（都为「别把普通文字误判成路径」）：
///
///  1. **只认带盘符的绝对路径**（`X:\` 或 `X:/`）。相对路径 `lib/ui/xxx.dart`
///     在有上下文时也有意义，但脱离上下文猜根目录会点错地方，宁可不识别。
///  2. **尾部标点要剥掉**：正文里的路径常被 `` ` ``、`）`、`，`、`。`、`.` 包围，
///     不剥就会拼出不存在的路径（手机上表现为「打不开」，很难排查）。
///  3. **`\\` 折叠成 `\`**：代码块里的 JSON 会把反斜杠写成两个，
///     `F:\\插件\\x.md` 直接拿去 fs.list 是不存在的。
///  4. **去重 + 限量**：同一条消息里同一个路径可能出现多次（正文 + 代码块），
///     界面上只留一条；最多 4 条，避免一条消息下面挂一屏按钮。
library;

/// 一条被识别出来的路径。
class FoundPath {
  /// 原样出现的形式（可能带 `\\`、带尾部标点），用于和正文对照。
  final String raw;

  /// 规整后、可以直接喂给 `fs.list` 的形式。
  final String path;

  /// 看着像文件（有扩展名）还是目录。
  final bool looksLikeFile;

  const FoundPath({
    required this.raw,
    required this.path,
    required this.looksLikeFile,
  });

  @override
  String toString() => 'FoundPath($path)';
}

/// 尾部要剥掉的字符。中英文标点都列上 —— 正文里路径后面跟着什么都可能。
const _trailingJunk =
    ' \t\r\n'
    '`"\'<>'
    ',.;:!?'
    '，。；：！？、'
    '）)】]｝}'
    '」』》';

/// 带盘符的绝对路径。
///
/// 字符集是**逐个排除**出来的（不是白名单），因为路径里可以出现中文、空格以外的
/// 绝大多数字符：
///   - 排除空白：`F:\插件\dsh-mobile 下面找` 里的「下面找」不能被吃进路径
///   - 排除中英文标点：路径常被 `「` `（` `，` `。` 包着
///   - 排除 `:` —— 盘符后面不会再有冒号
///
/// 前面的 `(?<![A-Za-z0-9:/\\])` 是为了不在 URL 中间误命中：
/// `http://example.com/a/b` 里的 `p:/` 不是盘符，`file:///F:/x` 里的 `e:/` 也不是。
final RegExp _winPath = RegExp(
  r'(?<![A-Za-z0-9:/\\])[A-Za-z]:[\\/][^\s"<>|*?`'
  r'，。；：！？、（）【】「」『』《》,;:\[\]{}]*',
);

/// `file:///F:/x` 形式。单独匹配，否则上面的规则会把它当成 `e:/`。
final RegExp _fileUrlRe = RegExp(
  r'file:///[A-Za-z]:[\\/][^\s"<>|*?`，。；：！？、（）【】「」『』《》]*',
  caseSensitive: false,
);

/// 扩展名判定：最后一个 `.` 之后 1~8 个字母数字，且整段不是纯盘符。
final RegExp _extRe = RegExp(r'\.[A-Za-z0-9]{1,8}$');

/// 从一段文本里扫出可用的路径。
///
/// 返回顺序 = 出现顺序；去重按**规整后**的字符串。
List<FoundPath> scanPaths(String text, {int limit = 4}) {
  if (text.isEmpty) return const [];

  final hits = <(int, FoundPath)>[];

  // 1) 先摘 file:/// 形式，并把原位置用空格顶掉，免得再被当成盘符路径
  var work = text;
  for (final m in _fileUrlRe.allMatches(text)) {
    final raw = m.group(0)!;
    final p = normalizeFoundPath(raw);
    if (p == null) continue;
    hits.add((
      m.start,
      FoundPath(raw: raw, path: p, looksLikeFile: _extRe.hasMatch(p)),
    ));
    final blank = List.filled(raw.length, ' ').join();
    work = work.replaceRange(m.start, m.end, blank);
  }

  // 2) 普通盘符路径
  for (final m in _winPath.allMatches(work)) {
    final raw = m.group(0) ?? '';
    final p = normalizeFoundPath(raw);
    if (p == null) continue;
    hits.add((
      m.start,
      FoundPath(raw: raw, path: p, looksLikeFile: _extRe.hasMatch(p)),
    ));
  }

  hits.sort((a, b) => a.$1.compareTo(b.$1));

  final out = <FoundPath>[];
  final seen = <String>{};
  for (final (_, fp) in hits) {
    if (seen.add(fp.path.toLowerCase())) out.add(fp);
    if (out.length >= limit) break;
  }
  return out;
}

/// 把一段「看起来像路径」的字符串规整成可用路径；不可用返回 null。
///
/// 可单独调用（例如 markdown 里 `file:///F:/x` 这类链接）。
String? normalizeFoundPath(String input) {
  var s = input.trim();
  if (s.isEmpty) return null;

  // file:///F:/xxx → F:/xxx
  final low = s.toLowerCase();
  if (low.startsWith('file:///')) {
    s = s.substring(8);
  } else if (low.startsWith('file://')) {
    s = s.substring(7);
  }

  // 剥尾部标点（可能连剥几个，比如 "F:\a\b.md）," ）
  var changed = true;
  while (changed && s.isNotEmpty) {
    changed = false;
    final last = s[s.length - 1];
    if (_trailingJunk.contains(last)) {
      s = s.substring(0, s.length - 1);
      changed = true;
    }
  }
  if (s.isEmpty) return null;

  // 代码块里的 JSON 转义：\\ → \
  if (s.contains(r'\\')) s = s.replaceAll(r'\\', r'\');
  // 正斜杠统一成反斜杠（Windows 宿主），盘符后面统一 `\`
  s = s.replaceAll('/', r'\');

  // 必须是 `X:\...` 或 `X:\`
  if (s.length < 3) return null;
  if (!RegExp(r'^[A-Za-z]:\\').hasMatch(s)) return null;

  // 盘符根去掉多余字符，但保留 `X:\`
  if (s.length == 2) s = '$s\\';
  return s;
}

/// 取父目录。`F:\a\b.md` → `F:\a`；盘符根返回自身（宿主用 null 表示再往上）。
String parentDirPath(String path) {
  final p = path.endsWith(r'\') && path.length > 3
      ? path.substring(0, path.length - 1)
      : path;
  final i = p.lastIndexOf(r'\');
  if (i <= 2) return '${p.substring(0, 2)}\\'; // F:\
  return p.substring(0, i);
}
