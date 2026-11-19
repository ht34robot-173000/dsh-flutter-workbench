/// DSH 工作台 —— 圆形揭示式主题切换（Flutter 版）。
///
/// Kotlin 版为了做这个效果走了「PixelCopy 抓整屏快照 → 对快照套反色滤镜 →
/// 用 ClipPath 裁圆形 → 遮罩盖上去 → 动画结束提交主题」这条路。
/// 那条路的根本原因是 Android 的 View 树没法「就地再画一遍并换颜色」。
///
/// Flutter 这边不需要截图：同一个 widget 子树可以被读多次，
/// `ColorFiltered` 就能得到它的反色副本。所以：
///
///     圆外 → 真界面
///     圆内 → 同一个 widget 套 ColorFiltered 再画一遍，用 ClipPath 裁圆
///
/// 好处不止是「少一次截图」：
///   - 没有抓图失败这条路径（Kotlin 版抓图失败会退化成瞬间切换）
///   - 不占额外内存（不用 Bitmap.createBitmap 半屏 ARGB_8888）
///   - 动画天然跟手，不存在「拷贝没回来所以先闪一下」
///
/// ⚠️ **橙色仍然存在**。反色矩阵按亮度逐通道反算、不保色相：
///     #005FB8（蓝）→ #FFAE45（橙）
/// 这是数学，不是框架。真要去掉有两种做法（后续版本再做）：
///   1. 给强调色元素套一层不参与 `ColorFiltered` 的子树
///   2. 换成「只反相亮度」的色相保持矩阵
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 反色滤镜，端点对齐新旧主题。
///
/// 算法与 Kotlin 版 `buildInvertMatrix` 完全一致（连端点校正的推导都一样），
/// 所以串色表现也必然一致 —— 这样可以确认「换框架不会自动修好橙色」。
ColorFilter buildInvertFilter(bool toDark) {
  const darkBg = 0x000000;
  const lightBg = 0xF3F3F3;
  const darkText = 0xFFFFFF;
  const lightText = 0x1A1A1A;

  double luma(int rgb) {
    final r = (rgb >> 16) & 0xFF;
    final g = (rgb >> 8) & 0xFF;
    final b = rgb & 0xFF;
    return 0.299 * r + 0.587 * g + 0.114 * b;
  }

  final oldBg = luma(toDark ? lightBg : darkBg);
  final newBg = luma(toDark ? darkBg : lightBg);
  final oldTxt = luma(toDark ? lightText : darkText);
  final newTxt = luma(toDark ? darkText : lightText);

  final iBg = 255.0 - oldBg;
  final iTxt = 255.0 - oldTxt;
  final denom = iTxt - iBg;
  final m = denom.abs() > 1 ? (newTxt - newBg) / denom : 1.0;
  final c = newBg - m * iBg;

  final a = -m;
  final b = 255 * m + c;

  return ColorFilter.matrix(<double>[
    a, 0, 0, 0, b,
    0, a, 0, 0, b,
    0, 0, a, 0, b,
    0, 0, 0, 1, 0,
  ]);
}

/// 圆形裁剪器。
class CircleClipper extends CustomClipper<Path> {
  final Offset center;
  final double radius;

  CircleClipper(this.center, this.radius);

  @override
  Path getClip(Size size) => Path()
    ..addOval(Rect.fromCircle(center: center, radius: radius));

  @override
  bool shouldReclip(CircleClipper old) =>
      old.radius != radius || old.center != center;
}

/// 把「一次主题切换」包成一个动画节点。
///
/// 用法：把它放在 App 根部、套住整棵树，平时处于「已完成」状态不产生任何视觉影响；
/// 切换时重建它并触发一次动画。
///
/// 为什么不做成 Overlay：Overlay 拿不到「当前整棵树」作为 child 再画一遍 ——
/// OverlayEntry 的 builder 里再引用原树会形成循环。
/// 套在根部是唯一能让「反色副本」和「原图」是同一棵子树的方式。
class ThemeRevealScope extends StatefulWidget {
  /// 是否正在做揭示范。false 时直接显示 [child]，零开销。
  final bool active;

  /// 目标明暗（决定反色矩阵的两端）。
  final bool toDark;

  /// 圆心（一般是主题按钮的位置）。null 时用屏幕中心。
  final Offset? origin;

  /// 一轮动画结束。
  final VoidCallback? onCompleted;

  final Widget child;

  const ThemeRevealScope({
    super.key,
    required this.active,
    required this.toDark,
    required this.origin,
    this.onCompleted,
    required this.child,
  });

  @override
  State<ThemeRevealScope> createState() => _ThemeRevealScopeState();
}

class _ThemeRevealScopeState extends State<ThemeRevealScope>
    with SingleTickerProviderStateMixin {
  AnimationController? _ctrl;

  @override
  void initState() {
    super.initState();
    if (widget.active) _start();
  }

  @override
  void didUpdateWidget(ThemeRevealScope old) {
    super.didUpdateWidget(old);
    // 从「不活跃」变成「活跃」：开始一轮
    if (widget.active && !old.active) _start();
  }

  void _start() {
    _ctrl?.dispose();
    final c = AnimationController(
      vsync: this,
      // 460ms 沿用 Kotlin 版实测值。再短会显得仓促，再长会拖。
      duration: const Duration(milliseconds: 460),
    );
    c.addListener(() => setState(() {}));
    c.addStatusListener((s) {
      if (s == AnimationStatus.completed) widget.onCompleted?.call();
    });
    _ctrl = c;
    c.forward(from: 0);
  }

  @override
  void dispose() {
    _ctrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = _ctrl;
    if (!widget.active || ctrl == null) return widget.child;

    final size = MediaQuery.sizeOf(context);
    final origin = widget.origin ?? Offset(size.width / 2, size.height / 2);

    // SineInOut：两端导数为 0，速度连续。
    // Kotlin 版实测过两段式动画在接缝处速度突变 2.7 倍（用户感觉「卡一下」），
    // 所以这里也走单段。
    final t = ctrl.value;
    final eased = (-math.cos(t * math.pi) + 1) / 2;

    final dx = math.max(origin.dx, size.width - origin.dx);
    final dy = math.max(origin.dy, size.height - origin.dy);
    final maxR = math.sqrt(dx * dx + dy * dy) + 4;

    return Stack(
      children: [
        // 圆外：原画面
        widget.child,
        // 圆内：同一棵子树的反色副本
        Positioned.fill(
          child: IgnorePointer(
            child: ClipPath(
              clipper: CircleClipper(origin, maxR * eased),
              child: ColorFiltered(
                colorFilter: buildInvertFilter(widget.toDark),
                child: widget.child,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
