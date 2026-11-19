/// DSH 工作台 —— 顶部标题栏 + 底部导航的共用外壳。
///
/// ⚠️ 设计原则（2026-11-19 调整）：
///
/// 这里**不再逐个元素对齐 Kotlin 版的像素值**。原因：Kotlin 用
/// 手写 LinearLayout + 自定义 padding 拼出来的布局，Flutter 的
/// 布局算法（flex + Text 行高）和它天然不一致，硬凑会导致元素错位
/// —— 阶段②实测：为了让卡片高度差 1px 去调 `TextStyle.height`，
/// 结果把图标挤到了文字上方。
///
/// 现在的标准是：
///   ✅ **配色令牌逐值一致**（DshColors 全部从 Kotlin 抄）
///   ✅ **Mica 两层渐变背景一致**（见 theme.dart 的 MicaBackdrop）
///   ✅ **圆角/描边/层级的观感一致**
///   ✅ 用 Flutter 自己的布局习惯，元素间距用「合理值」而不是「对齐值」
///
/// 这样既保住「看起来还是那个软件」，又不会因为硬凑而错位。
library;

import 'package:flutter/material.dart';

import 'icons.dart';
import 'theme.dart';

/// 一屏的外壳：Mica 背景 + 标题栏 + 内容 + 底部两格。
class WorkbenchShell extends StatelessWidget {
  final bool dark;
  final Widget body;
  final int currentTab;
  final ValueChanged<int> onTab;
  final VoidCallback onMenu;
  final VoidCallback onToggleTheme;
  final VoidCallback onSettings;

  const WorkbenchShell({
    super.key,
    required this.dark,
    required this.body,
    required this.currentTab,
    required this.onTab,
    required this.onMenu,
    required this.onToggleTheme,
    required this.onSettings,
  });

  @override
  Widget build(BuildContext context) {
    final c = DshColors.of(dark);
    return Scaffold(
      // 透明：让下面的 Mica 背景透上来。
      // 给 backgroundColor 会让它盖住 Mica，背景就变成一片纯色。
      backgroundColor: Colors.transparent,
      body: SizedBox.expand(
        child: MicaBackdrop(
          dark: dark,
          child: SafeArea(
            child: Column(
              children: [
                _titleBar(c),
                Expanded(child: body),
                _tabBar(c),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _titleBar(DshColors c) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Row(
        children: [
          _iconButton(DshGlyph.menu, c.textPrimary, onMenu),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(
                'DSH 工作台',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: c.textPrimary,
                ),
              ),
            ),
          ),
          _iconButton(DshGlyph.contrast, c.textPrimary, onToggleTheme),
          _iconButton(DshGlyph.settings, c.textPrimary, onSettings),
        ],
      ),
    );
  }

  /// 纯图标按钮。图标本身是固定尺寸的叶子节点，不会参与 Row 的 flex。
  Widget _iconButton(DshGlyph glyph, Color color, VoidCallback onTap) {
    return IconButton(
      onPressed: onTap,
      icon: DshIcon(glyph, size: 20, color: color),
      // 去掉 Material 默认的 48dp 最小尺寸，贴合 Kotlin 版的紧凑标题栏
      constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      splashRadius: 20,
    );
  }

  Widget _tabBar(DshColors c) {
    const tabs = [
      (DshGlyph.chat, '对话'),
      (DshGlyph.person, '我的'),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      child: Row(
        children: [
          for (var i = 0; i < tabs.length; i++)
            Expanded(
              child: _tabCell(
                c,
                tabs[i].$1,
                tabs[i].$2,
                active: i == currentTab,
                onTap: () => onTab(i),
              ),
            ),
        ],
      ),
    );
  }

  Widget _tabCell(
    DshColors c,
    DshGlyph glyph,
    String label, {
    required bool active,
    required VoidCallback onTap,
  }) {
    final color = active ? c.accent : c.textTertiary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          // 选中格给一层极淡底色，让「当前在哪一页」一眼可见
          color: active
              ? (dark ? const Color(0x33FFFFFF) : const Color(0x14000000))
              : null,
          borderRadius: BorderRadius.circular(8),
        ),
        // mainAxisSize.min + 居中：Row 不抢满整格宽度，图标和文字自然排一起
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            DshIcon(glyph, size: 18, color: color),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                color: color,
                fontWeight: active ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
