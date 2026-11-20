/// DSH 工作台 —— 对话里的「进行时」行（工具调用摘要 + 可展开详情）。
///
/// 对应桌面端那几行：
///
/// ```
/// >_ 执行了命令并已写入文件
/// >_ 执行了命令，已读取文件，修改了文件
/// ⊗ 正在分析请求
/// ```
///
/// 手机上一行放得下的东西不多，所以：
///   - 收起态：图标 + 一句话摘要 + （进行中）小转圈；
///   - 点一下展开：逐个工具列出「名字 + 参数关键字段 + 结果前几行」，等宽字体、限高可滚。
///
/// 为什么详情要限高：`pwsh` 的输出动不动几百行（这次接手就见过 18KB 的），
/// 展开后整块铺开会把后面的对话顶到看不见。
library;

import 'package:flutter/material.dart';

import '../data/chat_activity.dart';
import 'icons.dart';
import 'theme.dart';

class ActivityRow extends StatelessWidget {
  final ChatActivity activity;
  final DshColors c;
  final bool expanded;
  final VoidCallback onToggle;

  const ActivityRow({
    super.key,
    required this.activity,
    required this.c,
    required this.expanded,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final failed = activity.failed;
    final color = failed ? c.danger : (activity.running ? c.accent : c.textTertiary);

    /*
     * 刻意做成**一条细行**，不是卡片。
     *
     * 一轮里可能有十几个 step，卡片会把整屏铺满、把真正的回答挤没了
     * （第一版就是卡片，实测一屏只放得下工具行）。
     * 桌面端也是细行 + 一句摘要，这里对齐。
     */
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 5),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    _glyph(color),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        activity.summary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: failed ? c.danger : c.textSecondary,
                        ),
                      ),
                    ),
                    if (activity.running)
                      SizedBox(
                        width: 10,
                        height: 10,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.5,
                          color: c.accent,
                        ),
                      )
                    else if (activity.entries.length > 1)
                      Text(
                        '${activity.entries.length} 步',
                        style: TextStyle(fontSize: 10, color: c.textTertiary),
                      ),
                    const SizedBox(width: 2),
                    Icon(
                      expanded ? Icons.expand_less : Icons.expand_more,
                      size: 14,
                      color: c.textTertiary,
                    ),
                  ],
                ),
                if (expanded) ...[
                  const SizedBox(height: 6),
                  for (var i = 0; i < activity.entries.length; i++)
                    _entry(c, activity.entries[i], i),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 终端提示符 `>_`：用自绘图标库里最接近的 bolt/chat 都不像，
  /// 这里干脆用小号等宽字符 + 主色，形状和桌面端一致。
  Widget _glyph(Color color) {
    return SizedBox(
      width: 16,
      height: 14,
      child: CustomPaint(painter: _PromptPainter(color)),
    );
  }

  Widget _entry(DshColors c, ToolEntry e, int index) {
    final arg = e.argSummary;
    final res = (e.result ?? '').trim();

    return Padding(
      padding: EdgeInsets.only(top: index == 0 ? 0 : 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              DshIcon(
                e.failed ? DshGlyph.info : DshGlyph.bolt,
                size: 11,
                color: e.failed ? c.danger : c.textTertiary,
              ),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  e.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: e.failed ? c.danger : c.textSecondary,
                  ),
                ),
              ),
              if (!e.done)
                Text('执行中…', style: TextStyle(fontSize: 10, color: c.accent)),
            ],
          ),
          if (arg.isNotEmpty) ...[
            const SizedBox(height: 3),
            _mono(c, arg, maxLines: 6),
          ],
          if (e.error != null) ...[
            const SizedBox(height: 3),
            _mono(c, '错误：${e.error}', maxLines: 3, color: c.danger),
          ] else if (res.isNotEmpty) ...[
            const SizedBox(height: 3),
            _mono(c, res, maxLines: 10),
          ],
        ],
      ),
    );
  }

  Widget _mono(DshColors c, String text, {int maxLines = 8, Color? color}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: c.isDark ? const Color(0xFF0A0A0A) : const Color(0xFFFFFFFF),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: c.stroke),
      ),
      child: Text(
        text,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 10.5,
          height: 1.4,
          fontFamily: 'monospace',
          color: color ?? c.textSecondary,
        ),
      ),
    );
  }
}

/// `>_` 提示符。
class _PromptPainter extends CustomPainter {
  final Color color;
  _PromptPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    final path = Path()
      ..moveTo(1.5, size.height * 0.15)
      ..lineTo(size.width * 0.38, size.height * 0.5)
      ..lineTo(1.5, size.height * 0.85);
    canvas.drawPath(path, p);
    // 下划线
    final l = Paint()
      ..color = color
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(size.width * 0.5, size.height * 0.82),
      Offset(size.width * 0.95, size.height * 0.82),
      l,
    );
  }

  @override
  bool shouldRepaint(_PromptPainter old) => old.color != color;
}
