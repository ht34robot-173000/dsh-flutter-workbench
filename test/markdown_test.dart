// 对话正文 Markdown 渲染的冒烟测试。
//
// 背景：气泡里原来用 `Text(m.text)`，于是宿主返回的 Markdown 原样显示
// （满屏 `**`、`|`、`` ` ``）。这里固定住「真的解析成富文本」这件事，
// 顺带覆盖两个容易退化的分支：超长正文退回纯文本、图片不联网。
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_workbench/ui/markdown_view.dart';
import 'package:dsh_workbench/ui/theme.dart';

Widget _wrap(Widget child, {bool dark = true}) => MaterialApp(
      theme: DshColors.of(dark).toThemeData(),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  testWidgets('粗体/行内代码/表格都被解析成 MarkdownBody（不是纯文本）', (tester) async {
    const src = '**加粗** 和 `code`\n\n| a | b |\n|---|---|\n| 1 | 2 |\n';
    await tester.pumpWidget(_wrap(DshMarkdown(src, c: DshColors.of(true))));
    await tester.pumpAndSettle();

    expect(find.byType(MarkdownBody), findsOneWidget);
    // 原始标记不应该再出现在界面文本里
    expect(find.textContaining('**加粗**'), findsNothing);
    expect(find.textContaining('| a | b |'), findsNothing);
    // 内容本身要在
    expect(find.textContaining('加粗'), findsOneWidget);
  });

  testWidgets('标题与代码块能渲染，不抛异常', (tester) async {
    const src = '## 小标题\n\n```dart\nvoid main() {}\n```\n';
    await tester.pumpWidget(_wrap(DshMarkdown(src, c: DshColors.of(false))));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('小标题'), findsOneWidget);
  });

  testWidgets('超长正文退回纯文本（不解析，避免掉帧）', (tester) async {
    final big = 'x' * (kMarkdownMaxChars + 10);
    await tester.pumpWidget(_wrap(DshMarkdown(big, c: DshColors.of(true))));
    await tester.pumpAndSettle();
    expect(find.byType(MarkdownBody), findsNothing);
    expect(find.byType(Text), findsWidgets);
  });

  testWidgets('图片给占位标签，不去下载', (tester) async {
    const src = '看图 ![截图](https://example.com/a.png) 完';
    await tester.pumpWidget(_wrap(DshMarkdown(src, c: DshColors.of(true))));
    await tester.pumpAndSettle();
    // 占位里带 alt 文案，且没有 Image.network 去联网
    expect(find.textContaining('[截图]'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });
}
