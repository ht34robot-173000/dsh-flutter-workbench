/// DSH 工作台 —— 配色与主题。
///
/// 配色表直接照搬 Kotlin 版（那套是在纯黑背景上反复调出来的）：
///   暗色 WinBg #000000，卡片靠 #1A1A1A + 18% 白描边分层
///   亮色 WinBg #F3F3F3
///
/// ⚠️ 一条从 Kotlin 版带过来的铁律：**纯黑上不能靠大块灰填充分层**，
/// 只能靠描边 + 极轻微提亮 + 圆角间距。把卡片灰调亮会显得「浮起来」。
library;

import 'package:flutter/material.dart';

class DshColors {
  final bool isDark;
  const DshColors(this.isDark);

  static const _dark = DshColors(true);
  static const _light = DshColors(false);
  static DshColors of(bool dark) => dark ? _dark : _light;

  Color get winBg => isDark ? const Color(0xFF000000) : const Color(0xFFF3F3F3);

  /// Mica 底「铺底色」用的那一层。和 winBg 略有区别：
  /// 暗色也是纯黑，亮色是 #F9F9F9（比 winBg 的 #F3F3F3 更亮一点）。
  /// 这两个值都直接从 Kotlin 的 `MicaBackdrop.DARK_MICA / LIGHT_MICA` 抄的。
  Color get micaBg => isDark ? const Color(0xFF000000) : const Color(0xFFF9F9F9);
  Color get cardSolid => isDark ? const Color(0xFF1A1A1A) : const Color(0xFFFFFFFF);
  Color get cardBg => isDark ? const Color(0xFF141414) : const Color(0xADFFFFFF);

  /// 描边是纯黑上唯一的层次来源。暗色 18% 白，亮色 6% 黑。
  Color get stroke => isDark ? const Color(0x2EFFFFFF) : const Color(0x0F000000);

  Color get textPrimary => isDark ? const Color(0xFFF2F2F2) : const Color(0xFF1A1A1A);
  Color get textSecondary => isDark ? const Color(0xFFB4B4B4) : const Color(0xFF606060);
  Color get textTertiary => const Color(0xFF8A8A8A);

  /// 主色。两个主题都是蓝 —— 不要拿它当「随主题反转的前景色」用。
  Color get accent => isDark ? const Color(0xFF60A5FA) : const Color(0xFF005FB8);

  /// 强调色上的文字。暗色主题下 accent 是浅蓝，所以字要黑。
  Color get onAccent => isDark ? const Color(0xFF000000) : const Color(0xFFFFFFFF);

  Color get danger => isDark ? const Color(0xFFFF7A6B) : const Color(0xFFC42B1C);
  Color get success => isDark ? const Color(0xFF5CC75C) : const Color(0xFF107C10);

  /// 弹层外壳
  Color get sheetFill => isDark ? const Color(0xFF161616) : const Color(0xFFFAFAFA);

  /// 输入框底
  Color get inputFill => isDark ? const Color(0xFF141414) : const Color(0xFFF2F6F6);

  ThemeData toThemeData() {
    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: isDark ? Brightness.dark : Brightness.light,
    ).copyWith(
      surface: winBg,
      primary: accent,
      onPrimary: onAccent,
      error: danger,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: winBg,
      // 字体走系统默认。Kotlin 版也没嵌字体，靠系统中文渲染。
      fontFamily: null,
      appBarTheme: AppBarTheme(
        backgroundColor: winBg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        titleTextStyle: TextStyle(
          color: textPrimary,
          fontSize: 16,
          fontWeight: FontWeight.bold,
        ),
        iconTheme: IconThemeData(color: textPrimary),
      ),
      dividerColor: stroke,
      splashFactory: InkSparkle.splashFactory,
    );
  }
}

/// 一个 Fluent 风格的卡片容器：圆角 + 描边 + 极轻提亮。
///
/// 为什么不用 `Card`：Material 的 Card 自带 elevation 阴影和 surfaceTint，
/// 在纯黑背景上会糊成一团灰，和 Kotlin 版调出来的观感完全不同。
/// 这里自己画：只填充一个近乎不透明的底色，层次全靠 1px 描边。
class FluentCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final double radius;
  final Color? fill;
  final VoidCallback? onTap;

  const FluentCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.margin,
    this.radius = 12,
    this.fill,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = DshColors.of(Theme.of(context).brightness == Brightness.dark);
    final box = Container(
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: fill ?? c.cardSolid,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: c.stroke, width: 1),
      ),
      child: child,
    );
    if (onTap == null) return box;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(radius),
        onTap: onTap,
        child: box,
      ),
    );
  }
}

/// Mica 背景 —— **和 Kotlin 版逐值一致**的两层径向渐变。
///
/// Kotlin `MicaBackdrop.kt` 的画法：
///
///   1. `canvas.drawColor(micaOf(dark))` 铺底
///   2. 两层 RadialGradient，每个都用 `paint.alpha` 控制强度：
///      冷光 圆心 (0.12w, -0.08h) 半径 0.95w
///           暗 #2A4A6E alpha **28** / 亮 #D8E8FA alpha **150**
///      暖光 圆心 (1.05w, 1.15h) 半径 1.00w
///           暗 #4A3A22 alpha **22** / 亮 #FAF0E0 alpha **135**
///
/// ⚠️ 三个必须照抄的点（阶段②踩过）：
///
///  1. **alpha 是 `paint.alpha`（整层不透明度），不是颜色自带的 alpha。**
///     写成 `color.withValues(alpha: 28/255)` 数学上等价；但如果把 gradient
///     的第二个 stop 设成 `0x00000000`（纯透明黑），叠加时会按 premultiplied
///     alpha 拉低整体亮度 —— 实测整块背景比 Kotlin 暗 30~60。
///     正确做法是第二 stop 用**同色的 0 alpha**，而不是黑色。
///
///  2. **底色必须真的铺满**。Kotlin 第一行就 drawColor。Flutter 这边
///     如果只给 `ColoredBox` 包一层，子树的高度可能撑不满整屏，
///     露出的部分就是灰的（实测 #BCBCBC）。
///     所以这里在 painter 里先画一次底色，不依赖外层容器。
///
///  3. 暗色的 28/22 是**故意压极低**的：早先 110/95 铺到纯黑上会明显
///     发蓝发棕，看着像「没铺满」。
class MicaBackdrop extends StatelessWidget {
  final bool dark;
  final Widget child;
  const MicaBackdrop({super.key, required this.dark, required this.child});

  @override
  Widget build(BuildContext context) {
    final c = DshColors.of(dark);
    return CustomPaint(
      painter: _MicaPainter(dark, c.micaBg),
      // child 决定 CustomPaint 的尺寸。给一个撑满的容器，保证背景铺满整屏
      child: child,
    );
  }
}

class _MicaPainter extends CustomPainter {
  final bool dark;
  final Color base;
  _MicaPainter(this.dark, this.base);

  /// Kotlin 的 `RadialGradient(cx, cy, r, ...)` 用像素坐标，
  /// Flutter 用 `Alignment`（-1..1）+ 相对半径。这里做一次换算。
  static Alignment _align(double cx, double cy, double w, double h) =>
      Alignment(cx / w * 2 - 1, cy / h * 2 - 1);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return;
    final rect = Rect.fromLTWH(0, 0, w, h);

    // 1) 铺底 —— 对应 Kotlin 的 canvas.drawColor(micaOf(dark))
    canvas.drawRect(rect, Paint()..color = base);

    // 2) 两层径向渐变
    void layer({
      required Alignment center,
      required double radiusPx,
      required Color color,
      required int alpha,
    }) {
      // ⚠️ 第二个 stop 用**同色 0 alpha**，不用纯透明黑：
      // 用黑色会把整体亮度往下拉（premultiplied 混合），实测暗 30~60
      final paint = Paint()
        ..shader = RadialGradient(
          center: center,
          radius: radiusPx / (w / 2),
          colors: [
            color.withValues(alpha: alpha / 255),
            color.withValues(alpha: 0),
          ],
          stops: const [0, 1],
        ).createShader(rect);
      canvas.drawRect(rect, paint);
    }

    // 冷光：左上偏蓝
    layer(
      center: _align(0.12 * w, -0.08 * h, w, h),
      radiusPx: 0.95 * w,
      color: dark ? const Color(0xFF2A4A6E) : const Color(0xFFD8E8FA),
      alpha: dark ? 28 : 150,
    );

    // 暖光：右下偏棕/米
    layer(
      center: _align(1.05 * w, 1.15 * h, w, h),
      radiusPx: 1.0 * w,
      color: dark ? const Color(0xFF4A3A22) : const Color(0xFFFAF0E0),
      alpha: dark ? 22 : 135,
    );
  }

  @override
  bool shouldRepaint(_MicaPainter old) =>
      old.dark != dark || old.base != base;
}
