/// DSH 工作台 —— 圆形揭示式主题切换（快照版）。
///
/// ## 为什么从「同一棵子树画两遍」改成「抓一帧快照」
///
/// 上一版的做法是 Kotlin 那套思路的直译：把 `widget.child` 同时放进
/// `Stack` 的两个格子里，圆外看原图、圆内看套了反色滤镜的副本。
/// 好处是不用截图，但有一个**致命的副作用**：
///
///   Flutter 的 Element 是「位置 + 类型」认的。同一个 widget 出现两次
///   → 建两个独立 Element 树 → **两个独立 State**。
///   于是每次切主题：
///     ① 进切换态：旧的 State 被丢掉，新建**两个** `SessionListPage`
///        → 两次 `session.list` 请求 + 两个转圈
///     ② 动画结束：`Stack` 变回 `child`，两个 State 又被丢掉，再新建一个
///        → 第三次请求 + 第三次转圈
///
/// 用户看到的就是「点一下主题，列表闪白一下重新加载」，滚动位置也没了。
///
/// 现在改成：
///
///   1. 点主题 → 对**当前**这棵树 `toImage()` 抓一帧（旧外观）
///   2. 抓到之后才真正切主题（`onCaptured`），树就地重绘成新外观
///   3. 把那一帧**盖在最上面**，用「整屏减去圆形」的裁剪挖一个洞
///   4. 洞慢慢变大 → 新界面从洞口透出来；动画结束扔掉快照
///
/// 关键点：**活的那棵树从头到尾只有一份**，而且位置固定在 `Stack` 的第 0 个
/// 格子里 —— 结构没变，Element 就不会被销毁重建，页面 State、滚动位置、
/// 输入到一半的文字全都保留，一次网络请求都不会多发。
///
/// 代价：一次 `toImage()`（全屏 ARGB 快照，1080p 约 8 MB，动画结束即 dispose）。
/// 换来的是「切换零加载」，这笔账很划算。
///
/// ## 那个橙色仍然存在（数学问题，不是实现问题）
///
/// Kotlin 版的反色矩阵按亮度逐通道反算、不保色相：`#005FB8`（蓝）→ `#FFAE45`（橙）。
/// 现在这条路根本不反色了（直接快照旧画面），所以**橙色消失了**——
/// 用户当初选择「改回反色」是为了保留换主题时的辨识度，这里由圆形揭示本身承担。
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// 圆形裁剪：**只保留圆外的部分**。
///
/// 快照层要「除了洞口以外都盖住」，所以是反向裁剪。
/// 用 evenOdd 填充规则让「整屏矩形 ∩ 圆」的部分变成空洞，
/// 比 `Path.combine(difference, ...)` 少一次路径运算。
class InverseCircleClipper extends CustomClipper<Path> {
  final Offset center;
  final double radius;

  InverseCircleClipper(this.center, this.radius);

  @override
  Path getClip(Size size) => Path()
    ..fillType = PathFillType.evenOdd
    ..addRect(Offset.zero & size)
    ..addOval(Rect.fromCircle(center: center, radius: radius));

  @override
  bool shouldReclip(InverseCircleClipper old) =>
      old.radius != radius || old.center != center;
}

/// 把「一次主题切换」包成一个动画节点。
///
/// 用法：放在 App 根部、套住整棵树。平时就是一个 `Stack + RepaintBoundary`，
/// 不产生视觉影响；切换时抓快照 → 切主题 → 播放揭示动画。
class ThemeRevealScope extends StatefulWidget {
  /// 是否请求了一次切换。真正什么时候换主题由本组件决定（抓完快照之后）。
  final bool active;

  /// 目标明暗（只用于日志/断言，颜色由 MaterialApp 的主题决定）。
  final bool toDark;

  /// 圆心（一般是主题按钮的位置）。null 时用屏幕中心。
  final Offset? origin;

  /// **快照已拿到**，现在可以真正切换主题了。
  final VoidCallback? onCaptured;

  /// 一轮动画结束（快照已释放）。
  final VoidCallback? onCompleted;

  final Widget child;

  const ThemeRevealScope({
    super.key,
    required this.active,
    required this.toDark,
    required this.origin,
    this.onCaptured,
    this.onCompleted,
    required this.child,
  });

  @override
  State<ThemeRevealScope> createState() => _ThemeRevealScopeState();
}

class _ThemeRevealScopeState extends State<ThemeRevealScope>
    with SingleTickerProviderStateMixin {
  /// 包住整棵树，用来抓帧。**必须始终存在**（位置不变才不重建 Element）。
  final _shotKey = GlobalKey();

  ui.Image? _snapshot;
  AnimationController? _ctrl;

  /// 正在抓帧/播动画。用于挡住连点（第二次点击直接跳过，不排队）。
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.active) _begin();
  }

  @override
  void didUpdateWidget(ThemeRevealScope old) {
    super.didUpdateWidget(old);
    // 从「不活跃」变成「活跃」：开始一轮
    if (widget.active && !old.active) _begin();
  }

  @override
  void dispose() {
    _ctrl?.dispose();
    _snapshot?.dispose();
    super.dispose();
  }

  Future<void> _begin() async {
    if (_busy) {
      // 连点：不排队，直接按「瞬时切换」处理，免得状态卡在 active 上下不来
      widget.onCaptured?.call();
      widget.onCompleted?.call();
      return;
    }
    _busy = true;
    debugPrint(
      '[reveal] start dur=${const int.fromEnvironment('DSH_REVEAL_MS', defaultValue: 460)}ms '
      'origin=${widget.origin}',
    );

    final img = await _capture();
    if (!mounted) {
      _busy = false;
      img?.dispose();
      return;
    }

    if (img == null) {
      // 抓不到帧（极端情况：根节点还没完成布局）。不能卡在这里，
      // 直接切主题 —— 用户体验成「瞬时切换」，但**不能有加载**
      debugPrint('[reveal] capture failed → 瞬时切换');
      widget.onCaptured?.call();
      widget.onCompleted?.call();
      _busy = false;
      return;
    }

    debugPrint('[reveal] captured ${img.width}x${img.height}');

    setState(() => _snapshot = img);

    /*
     * 快照已经安全拿在手里了，**现在**才切主题。
     *
     * 顺序不能反：先切主题的话抓到的就是新外观，动画会变成「新的盖新的」，
     * 一点效果都看不到。
     */
    widget.onCaptured?.call();

    final c = AnimationController(
      vsync: this,
      // 460ms 沿用 Kotlin 版实测值。再短显得仓促，再长会觉得拖。
      //
      // 可调：`--dart-define=DSH_REVEAL_MS=2000` 把动画放慢，
      // 用来**截到动画中途的帧**验证圆心位置（adb screencap 一次就要几百毫秒，
      // 460ms 的动画经常截完已经播完了）。
      duration: const Duration(
        milliseconds: int.fromEnvironment('DSH_REVEAL_MS', defaultValue: 460),
      ),
    );
    c.addListener(() => setState(() {}));
    c.addStatusListener((s) {
      if (s != AnimationStatus.completed) return;
      if (!mounted) return;
      setState(() {
        _snapshot?.dispose();
        _snapshot = null;
      });
      _busy = false;
      widget.onCompleted?.call();
    });

    _ctrl?.dispose();
    _ctrl = c;
    c.forward(from: 0);
  }

  /// 抓当前整棵树的一帧。失败返回 null（不抛 —— 主题切换不能因为抓帧失败而卡死）。
  Future<ui.Image?> _capture() async {
    try {
      final ro = _shotKey.currentContext?.findRenderObject();
      if (ro is! RenderRepaintBoundary) return null;
      // 用设备像素比抓，否则高 DPI 屏上快照会糊
      final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
      return await ro.toImage(pixelRatio: dpr <= 0 ? 1 : dpr);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    /*
     * ⚠️ **结构必须是稳定的**。
     *
     * 无论有没有快照，最外层都是这个 `Stack`，活的那棵树永远是第 0 个孩子。
     * 只在末尾「追加/移除」快照层 —— Flutter 按 index 对账，
     * 第 0 个孩子的类型和位置都没变，Element 原地复用，State 不会被销毁。
     *
     * 千万别写成 `if (snapshot == null) return child;` —— 那样从 Stack 变回
     * child，整棵树重建，就等于回到「切主题掉一次 State」的老问题。
     */
    final img = _snapshot;
    final ctrl = _ctrl;

    return Stack(
      fit: StackFit.expand,
      children: [
        RepaintBoundary(key: _shotKey, child: widget.child),
        if (img != null) _buildSnapshotLayer(context, img, ctrl),
      ],
    );
  }

  Widget _buildSnapshotLayer(
    BuildContext context,
    ui.Image img,
    AnimationController? ctrl,
  ) {
    final size = MediaQuery.sizeOf(context);
    final origin = widget.origin ?? Offset(size.width / 2, size.height / 2);

    // SineInOut：两端导数为 0，速度连续。
    // Kotlin 版实测过两段式动画在接缝处速度突变 2.7 倍（用户感觉「卡一下」），
    // 所以这里也走单段。
    final t = ctrl?.value ?? 1.0;
    final eased = (-math.cos(t * math.pi) + 1) / 2;

    final dx = math.max(origin.dx, size.width - origin.dx);
    final dy = math.max(origin.dy, size.height - origin.dy);
    final maxR = math.sqrt(dx * dx + dy * dy) + 4;

    return Positioned.fill(
      child: IgnorePointer(
        child: ClipPath(
          clipper: InverseCircleClipper(origin, maxR * eased),
          // fit: fill —— 快照就是整屏，等比缩放会把圆形和边缘错开
          child: RawImage(image: img, fit: BoxFit.fill),
        ),
      ),
    );
  }
}
