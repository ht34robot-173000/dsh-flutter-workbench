/// DSH 工作台 —— 主题切换按钮（每个页面都能用）。
///
/// 为什么抽成公共组件：原来它只存在于首页标题栏（`workbench_shell.dart` 里的
/// 私有 `_ThemeToggleButton`），进了对话页 / 文件管理 / 设置页就没有切换入口了。
///
/// ⚠️ 这个按钮**必须自己上报点击位置**（圆心）。主题揭示动画是「从按钮位置
/// 扩一个圆」，圆心要靠 `RenderBox.localToGlobal` 现算 —— 页面自己算不了
/// （它不知道按钮在哪），所以封装在这里，页面上只要 `const ThemeToggleButton()`。
library;

import 'package:flutter/material.dart';

import '../main.dart' show AppScope;
import 'icons.dart';

class ThemeToggleButton extends StatefulWidget {
  /// 图标颜色。不给就用 `DshColors.textPrimary`。
  final Color? color;

  /// 尺寸。默认 20（标题栏用），侧边栏里可以用 18。
  final double size;

  const ThemeToggleButton({super.key, this.color, this.size = 20});

  @override
  State<ThemeToggleButton> createState() => _ThemeToggleButtonState();
}

class _ThemeToggleButtonState extends State<ThemeToggleButton> {
  final _key = GlobalKey();

  void _handleTap() {
    final state = AppScope.of(context);
    final ro = _key.currentContext?.findRenderObject();
    Offset? center;
    if (ro is RenderBox && ro.hasSize && ro.attached) {
      // localToGlobal 给的是根视图坐标，和 ThemeRevealScope 里
      // MediaQuery.sizeOf 的坐标系一致（都是逻辑像素、从屏幕左上角算）
      center = ro.localToGlobal(ro.size.center(Offset.zero));
    }
    state.toggleTheme(origin: center);
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? Colors.grey;
    return IconButton(
      key: _key,
      onPressed: _handleTap,
      icon: DshIcon(DshGlyph.contrast, size: widget.size, color: color),
      constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      splashRadius: 20,
      tooltip: '切换深浅色',
    );
  }
}
