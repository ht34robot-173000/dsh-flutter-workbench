#!/usr/bin/env python3
"""生成 DSH 工作台的 App 图标（不用任何图片素材，纯几何绘制）。

为什么自己画而不是 AI 出图：
  - 图标要在 48px 下仍然认得出来，必须**可控的粗几何**，AI 出图细节一多就糊；
  - 需要 5 个密度 + 自适应图标前景/背景 + 单色（Android 13 主题图标），
    同一套形状重生一遍比抠图可靠；
  - 版本可复现：改了颜色重跑一次就好。

设计：
  深蓝渐变底 + 白色对话气泡 + 气泡里的终端提示符 `›_`
  —— 一句话说清这个 App：**在手机上跟 DSH 对话、下指令**。

输出（相对 android/app/src/main/res）：
  mipmap-{mdpi,hdpi,xhdpi,xxhdpi,xxxhdpi}/ic_launcher.png      48/72/96/144/192  旧式方形图标
  mipmap-{...}/ic_launcher_foreground.png                      108/162/216/324/432 自适应前景（透明）
  mipmap-{...}/ic_launcher_monochrome.png                      同上尺寸，单色剪影（Android 13+）
  drawable/ic_launcher_background.xml                          自适应背景（渐变）

用法：python tool/gen_icon.py
"""
from __future__ import annotations

import os
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(ROOT, "android", "app", "src", "main", "res")

S = 1024  # 母版尺寸，最后按密度缩放

# 配色：和 App 里的 DshColors 同源（深色底 + 蓝色强调）
BG_TOP = (31, 79, 216)  # #1F4FD8
BG_BOT = (10, 27, 60)  # #0A1B3C
BUBBLE = (248, 250, 252)  # #F8FAFC
CARET = (20, 45, 110)  # #142D6E
UNDER = (59, 130, 246)  # #3B82F6


def _lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def gradient_bg(size: int) -> Image.Image:
    """竖向渐变 + 左上角一团柔光（对应 App 的 Mica 冷光）。"""
    img = Image.new("RGB", (size, size), BG_BOT)
    d = ImageDraw.Draw(img)
    for y in range(size):
        d.line([(0, y), (size, y)], fill=_lerp(BG_TOP, BG_BOT, y / (size - 1)))

    glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    r = int(size * 0.62)
    gd.ellipse(
        [-int(size * 0.28), -int(size * 0.34), -int(size * 0.28) + 2 * r, -int(size * 0.34) + 2 * r],
        fill=(120, 170, 255, 70),
    )
    glow = glow.filter(ImageFilter.GaussianBlur(size * 0.06))
    img = Image.alpha_composite(img.convert("RGBA"), glow).convert("RGB")
    return img


def draw_glyph(canvas: int, scale: float = 1.0, single_color=None) -> Image.Image:
    """画「对话气泡 + ›_」。

    scale 用来给自适应图标的前景留安全区（前景内容只占中间的 66%）。
    single_color 非空时画成单色剪影（Android 13 主题图标）。
    """
    img = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    w = canvas * 0.58 * scale      # 气泡宽
    h = w * 0.80                   # 气泡高
    cx = canvas / 2
    cy = canvas / 2 - canvas * 0.012 * scale
    x0, y0 = cx - w / 2, cy - h / 2
    x1, y1 = cx + w / 2, cy + h / 2
    rad = h * 0.32

    bubble_fill = single_color if single_color else BUBBLE + (255,)
    d.rounded_rectangle([x0, y0, x1, y1], radius=rad, fill=bubble_fill)

    # 尾巴：左下角的小三角，让「这是气泡」一眼成立
    d.polygon(
        [
            (x0 + w * 0.19, y1 - h * 0.03),
            (x0 + w * 0.07, y1 + h * 0.26),
            (x0 + w * 0.44, y1 - h * 0.03),
        ],
        fill=bubble_fill,
    )

    if single_color:
        return img

    # —— 提示符 ›_ ——
    # 折线和下划线**底边对齐**，读起来才是终端里的 `>_`；
    # 线帽用圆点补，否则 joint="curve" 在顶点会留一个尖角缺口。
    stroke = max(2, int(w * 0.088))
    chev_h = h * 0.225
    chev_w = w * 0.135
    px = x0 + w * 0.275
    py = cy + h * 0.02

    caret_col = CARET + (255,)
    pts = [(px, py - chev_h), (px + chev_w, py), (px, py + chev_h)]
    d.line(pts, fill=caret_col, width=stroke, joint="curve")
    for (ex, ey) in (pts[0], pts[2]):
        r = stroke / 2
        d.ellipse([ex - r, ey - r, ex + r, ey + r], fill=caret_col)

    # 下划线：右端稍长，底边与折线底端齐平
    ux0 = px + chev_w + w * 0.055
    ux1 = ux0 + w * 0.265
    uy = py + chev_h
    d.rounded_rectangle(
        [ux0, uy - stroke * 0.5, ux1, uy + stroke * 0.5],
        radius=stroke * 0.5,
        fill=UNDER + (255,),
    )

    # 右上角三个小点（"正在输入"），暗示实时流；小尺寸下也不会糊成一坨
    dot_r = w * 0.019
    gap = dot_r * 3.6
    dx = x1 - w * 0.115
    dy = y0 + h * 0.20
    for i in range(3):
        d.ellipse(
            [dx - i * gap - dot_r, dy - dot_r, dx - i * gap + dot_r, dy + dot_r],
            fill=(59, 130, 246, 220),
        )

    return img


def legacy_icon(size: int, src_size: int) -> Image.Image:
    """旧式图标：渐变底 + 圆角裁切 + 内容。"""
    base = gradient_bg(src_size).convert("RGBA")
    base = Image.alpha_composite(base, draw_glyph(src_size, scale=1.0))

    # 圆角遮罩（Android 8 以下不会自己裁，图标本身要圆角）
    mask = Image.new("L", (src_size, src_size), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, src_size - 1, src_size - 1], radius=src_size * 0.22, fill=255)
    out = Image.new("RGBA", (src_size, src_size), (0, 0, 0, 0))
    out.paste(base, (0, 0), mask)
    return out.resize((size, size), Image.LANCZOS)


def main() -> None:
    densities = {
        "mdpi": 1.0,
        "hdpi": 1.5,
        "xhdpi": 2.0,
        "xxhdpi": 3.0,
        "xxxhdpi": 4.0,
    }

    fg_master = draw_glyph(S, scale=0.66)  # 自适应前景：内容压在中间 66% 安全区内
    mono_master = draw_glyph(S, scale=0.66, single_color=(255, 255, 255, 255))

    for name, mult in densities.items():
        d = os.path.join(RES, f"mipmap-{name}")
        os.makedirs(d, exist_ok=True)

        legacy = legacy_icon(int(48 * mult), S)
        legacy.save(os.path.join(d, "ic_launcher.png"), optimize=True)

        fg_size = int(108 * mult)  # 108dp 画布
        fg_master.resize((fg_size, fg_size), Image.LANCZOS).save(
            os.path.join(d, "ic_launcher_foreground.png"), optimize=True
        )
        mono_master.resize((fg_size, fg_size), Image.LANCZOS).save(
            os.path.join(d, "ic_launcher_monochrome.png"), optimize=True
        )
        print(f"mipmap-{name}: ic_launcher {int(48*mult)}px, foreground/monochrome {fg_size}px")

    # 自适应背景（渐变 drawable）
    drawable = os.path.join(RES, "drawable")
    os.makedirs(drawable, exist_ok=True)
    with open(os.path.join(drawable, "ic_launcher_background.xml"), "w", encoding="utf-8") as f:
        f.write(
            '<?xml version="1.0" encoding="utf-8"?>\n'
            "<!-- 自适应图标背景：竖向渐变，取色和 App 深色主题一致 -->\n"
            '<shape xmlns:android="http://schemas.android.com/apk/res/android"\n'
            '    android:shape="rectangle">\n'
            "    <gradient\n"
            '        android:angle="270"\n'
            '        android:startColor="#1F4FD8"\n'
            '        android:endColor="#0A1B3C"\n'
            '        android:type="linear" />\n'
            "</shape>\n"
        )
    print("drawable/ic_launcher_background.xml")

    # 顺便导一张 512 的给 README / 发布页用
    out_dir = os.path.join(ROOT, "docs")
    os.makedirs(out_dir, exist_ok=True)
    legacy_icon(512, S).save(os.path.join(out_dir, "icon-512.png"), optimize=True)
    print("docs/icon-512.png")


if __name__ == "__main__":
    main()
