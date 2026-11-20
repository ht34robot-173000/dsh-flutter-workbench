/// DSH 工作台 —— 对话正文的 Markdown 渲染。
///
/// 为什么需要：宿主返回的 `assistant/message` 正文是**标准 Markdown**
/// （`**粗体**`、`` `行内代码` ``、`## 标题`、`| 表格 |`、围栏代码块）。
/// 之前气泡里用的是 `Text(m.text)`，于是满屏都是原始的 `**` 和 `|`，
/// 表格塌成一串竖线 —— 用户一眼就看出来了。
///
/// 几条约束（都是踩过的）：
///
///  1. **表格**：flutter_markdown 0.7.x 的 `_buildTable` 自带
///     `SingleChildScrollView(horizontal)`，所以宽表格会横向滚，
///     不需要自己接管；只要给它一个**有界宽度**（气泡的 maxWidth 就够）。
///
///  2. **行内代码不要用 accent 色**：accent 是链接色，`code` 染成那个颜色后
///     看着和可点链接一模一样（更新页实测被用户点过）。
///     用主文字色 + 描边底，靠形态区分。
///
///  3. **图片不联网**：`![alt](url)` 默认会让 flutter_markdown 去下载图片，
///     手机走上行/公网隧道，白白流量还可能卡住。这里直接渲染成占位标签。
///
///  4. **超长正文退回纯文本**：Markdown 解析是纯 Dart 的，几万字会明显掉帧
///     （流式时每来一个 chunk 都要重新解析）。超过阈值就不解析。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import 'theme.dart';

/// 超过这个长度就不做 Markdown 解析（退回等宽纯文本，可滚动）。
/// 实测 20 KB 的正文解析一次约 10~20 ms，流式时会被放大成掉帧。
const int kMarkdownMaxChars = 20000;

class DshMarkdown extends StatelessWidget {
  final String data;
  final DshColors c;

  /// 气泡内用的紧凑版（正文 13.5）。false 时按文档正文 14 排。
  final bool bubble;

  const DshMarkdown(
    this.data, {
    super.key,
    required this.c,
    this.bubble = true,
  });

  @override
  Widget build(BuildContext context) {
    if (data.length > kMarkdownMaxChars) {
      // 超大正文：不解析，直接等宽显示（仍然可读、不爆内存）
      return Text(
        data,
        style: TextStyle(
          fontSize: bubble ? 12.5 : 13,
          height: 1.45,
          fontFamily: 'monospace',
          color: c.textPrimary,
        ),
      );
    }

    return MarkdownBody(
      data: data,
      // 气泡里不铺满：让 Column 按内容高度走
      shrinkWrap: true,
      styleSheet: _style(c),
      onTapLink: (text, href, title) => _onTapLink(context, href ?? text),
      // 图片不联网，给个占位（见文件头第 3 条）
      sizedImageBuilder: (cfg) => _imagePlaceholder(cfg.uri, cfg.alt),
    );
  }

  Future<void> _onTapLink(BuildContext context, String href) async {
    if (href.isEmpty) return;
    // 没有 url_launcher：不为了一个链接引入新依赖，直接复制到剪贴板。
    // 手机上「复制一下自己粘到浏览器」比「点开失败」有用。
    await Clipboard.setData(ClipboardData(text: href));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text('链接已复制：$href', maxLines: 2, overflow: TextOverflow.ellipsis),
          duration: const Duration(seconds: 3),
        ),
      );
  }

  MarkdownStyleSheet _style(DshColors c) {
    final body = TextStyle(
      fontSize: bubble ? 13.5 : 14,
      height: 1.45,
      color: c.textPrimary,
    );
    // 行内代码 / 代码块统一等宽。字号略小一档，避免把行高撑开。
    final mono = body.copyWith(
      fontFamily: 'monospace',
      fontSize: (bubble ? 12 : 12.5),
      height: 1.4,
    );

    return MarkdownStyleSheet(
      p: body,
      pPadding: EdgeInsets.zero,
      strong: body.copyWith(fontWeight: FontWeight.w700),
      em: body.copyWith(fontStyle: FontStyle.italic),
      del: body.copyWith(decoration: TextDecoration.lineThrough),
      a: body.copyWith(color: c.accent, decoration: TextDecoration.underline),
      // 行内代码：主文字色 + 极淡底（不要 accent，见文件头第 2 条）
      code: mono.copyWith(
        backgroundColor: c.isDark ? const Color(0xFF232323) : const Color(0xFFEFEFEF),
      ),
      codeblockDecoration: BoxDecoration(
        color: c.isDark ? const Color(0xFF141414) : const Color(0xFFF4F4F4),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: c.stroke),
      ),
      codeblockPadding: const EdgeInsets.all(9),
      blockSpacing: 8,
      listIndent: 16,
      listBullet: body.copyWith(color: c.textSecondary),
      blockquote: body.copyWith(color: c.textSecondary),
      blockquotePadding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
      blockquoteDecoration: BoxDecoration(
        color: c.accent.withValues(alpha: 0.07),
        border: Border(left: BorderSide(color: c.accent, width: 2.5)),
        borderRadius: const BorderRadius.horizontal(right: Radius.circular(4)),
      ),
      h1: body.copyWith(fontSize: (bubble ? 16 : 18), fontWeight: FontWeight.bold),
      h2: body.copyWith(fontSize: (bubble ? 15 : 16.5), fontWeight: FontWeight.bold),
      h3: body.copyWith(fontSize: (bubble ? 14 : 15), fontWeight: FontWeight.bold),
      h4: body.copyWith(fontSize: (bubble ? 13.5 : 14), fontWeight: FontWeight.bold),
      h5: body.copyWith(fontSize: (bubble ? 13.5 : 14), fontWeight: FontWeight.w600),
      h6: body.copyWith(fontSize: (bubble ? 13.5 : 14), fontWeight: FontWeight.w600),
      // 标题上下的空档压小一点，气泡里不然很松
      h1Padding: const EdgeInsets.only(top: 2),
      h2Padding: const EdgeInsets.only(top: 2),
      h3Padding: const EdgeInsets.only(top: 2),
      horizontalRuleDecoration: BoxDecoration(
        border: Border(top: BorderSide(color: c.stroke, width: 1)),
      ),
      // 表格：横向滚动是 flutter_markdown 自带的，这里只管观感
      tableHead: body.copyWith(fontWeight: FontWeight.bold, fontSize: (bubble ? 12.5 : 13)),
      tableBody: body.copyWith(fontSize: (bubble ? 12.5 : 13)),
      tableCellsPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      tableBorder: TableBorder.all(color: c.stroke, width: 1),
      tableColumnWidth: const IntrinsicColumnWidth(),
      tableScrollbarThumbVisibility: false,
    );
  }
  /// 图片占位。不下载任何东西，只把 alt 和地址显示出来。
  ///
  /// 用 `imageBuilder` 而不是自定义 `MarkdownElementBuilder`：
  /// 后者要 import `package:markdown/markdown.dart` 拿 `md.Element` 类型，
  /// 而那是 flutter_markdown 的**传递依赖**，直接 import 会触发
  /// `depend_on_referenced_packages`，逼着你把 markdown 也写进 pubspec。
  Widget _imagePlaceholder(Uri uri, String? alt) {
    final label = (alt == null || alt.isEmpty) ? '[图片]' : '[$alt]';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.image_outlined, size: 14, color: c.textTertiary),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: c.textSecondary),
            ),
          ),
          if (uri.toString().isNotEmpty)
            Flexible(
              child: Text(
                '  ${uri.toString()}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10.5, color: c.textTertiary),
              ),
            ),
        ],
      ),
    );
  }
}
