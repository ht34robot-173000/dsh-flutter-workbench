#!/usr/bin/env python3
"""生成 README / 发布页用的横幅图（图标 + 名字 + 一句话 + 特性标签）。

为什么用脚本画而不是截图拼：
  - 和图标同一套配色与几何，改一处两边一起变；
  - 中文排版要控制大小/字重/间距，手拼很容易歪；
  - 输出固定 1600×560，GitHub 在 README 里按容器宽度缩，不会糊。

用法：python tool/gen_banner.py
产物：docs/banner.png
"""
from __future__ import annotations

import os
import sys

from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_icon import BG_BOT, BG_TOP, draw_glyph, _lerp  # noqa: E402
from font_strawberry import draw_text, text_width  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "docs", "banner.png")

W, H = 1600, 560
RADIUS = 28

# 字体统一走 tool/font_strawberry.py（草莓字体 Aa 草莓可颂面包圆，
# 加粗用 stroke 模拟 —— 这个字体只有单字重）。


def bg(w, h):
    """左上亮、右下暗的对角渐变 + 顶部一团冷光。"""
    img = Image.new("RGB", (w, h), BG_BOT)
    d = ImageDraw.Draw(img)
    for y in range(h):
        d.line([(0, y), (w, y)], fill=_lerp(BG_TOP, BG_BOT, y / (h - 1)))
    # 对角再压一层暗，让右侧文字区更沉
    shade = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shade)
    for x in range(w):
        a = int(120 * (x / (w - 1)) ** 1.4)
        sd.line([(x, 0), (x, h)], fill=(4, 10, 26, a))
    return Image.alpha_composite(img.convert("RGBA"), shade)


def rounded_mask(w, h, r):
    m = Image.new("L", (w, h), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, w - 1, h - 1], radius=r, fill=255)
    return m


def main() -> None:
    canvas = bg(W, H)

    # —— 图标（左边，带一点投影）——
    icon_size = 300
    icon = draw_glyph(1024, scale=1.0).resize((icon_size, icon_size), Image.LANCZOS)
    plate = Image.new("RGBA", (icon_size, icon_size), (0, 0, 0, 0))
    plate.alpha_composite(icon)
    # 圆角底（和 App 图标一致）
    icon_bg = Image.new("RGBA", (icon_size, icon_size), (0, 0, 0, 0))
    grad = Image.new("RGB", (icon_size, icon_size), BG_BOT)
    gd = ImageDraw.Draw(grad)
    for y in range(icon_size):
        gd.line([(0, y), (icon_size, y)], fill=_lerp(BG_TOP, BG_BOT, y / (icon_size - 1)))
    icon_bg.alpha_composite(grad.convert("RGBA"))
    icon_bg.alpha_composite(plate)
    icon_bg.putalpha(rounded_mask(icon_size, icon_size, int(icon_size * 0.22)))

    shadow = Image.new("RGBA", (icon_size + 80, icon_size + 80), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        [40, 48, 40 + icon_size, 48 + icon_size],
        radius=int(icon_size * 0.22),
        fill=(0, 0, 0, 140),
    )
    from PIL import ImageFilter

    shadow = shadow.filter(ImageFilter.GaussianBlur(18))
    canvas.alpha_composite(shadow, (72, 96))
    canvas.alpha_composite(icon_bg, (112, 130))

    d = ImageDraw.Draw(canvas)
    x = 500

    # —— 标题（加粗 = 草莓字体 + stroke）——
    draw_text(d, (x, 128), "DSH 工作台", size=92, fill=(255, 255, 255), bold=True)

    # —— 副标题 ——
    draw_text(
        d,
        (x + 4, 248),
        "手机端远控 DeepSeek Harness",
        size=36,
        fill=(214, 226, 255),
    )

    # —— 一句话 ——
    draw_text(
        d,
        (x + 4, 306),
        "看实时输出 · 回消息 · 传文件 · 答提问 · 改主题",
        size=30,
        fill=(150, 178, 226),
    )

    # —— 特性标签 ——
    #
    # ⚠️ 这里**不能用半透明色**填 `ImageDraw`：在 RGBA 画布上它直接覆盖像素的
    # alpha（不是混色），而最后 `putalpha(圆角遮罩)` 又会把 alpha 全刷成 255，
    # 于是 (255,255,255,22) 会变成**纯白**药丸，文字反而看不清（第一版就是这样）。
    # 所以颜色先自己混好，写死成不透明值。
    chips = ["Markdown 正文", "路径直达", "主题零加载", "回答提问"]
    chip_fill = (34, 58, 118)
    chip_line = (96, 134, 214)
    chip_text = (228, 238, 255)
    cx, cy = x + 4, 380
    pad_x, pad_y, gap = 20, 10, 12
    for text in chips:
        tw = text_width(d, text, size=25)
        w_chip = int(tw + pad_x * 2)
        h_chip = 48
        d.rounded_rectangle(
            [cx, cy, cx + w_chip, cy + h_chip],
            radius=24,
            fill=chip_fill,
            outline=chip_line,
            width=1,
        )
        draw_text(d, (cx + pad_x, cy + pad_y + 2), text, size=25, fill=chip_text)
        cx += w_chip + gap

    # —— 右下角的 URL（右对齐，别顶到边）——
    url = "github.com/ht34robot-173000/dsh-flutter-workbench"
    url_w = text_width(d, url, size=22)
    draw_text(
        d,
        (W - url_w - 52, H - 54),
        url,
        size=22,
        fill=(128, 158, 208),
    )

    # 圆角裁切
    canvas.putalpha(rounded_mask(W, H, RADIUS))
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    canvas.save(OUT, optimize=True)
    print(f"{OUT}  {canvas.size[0]}x{canvas.size[1]}")


if __name__ == "__main__":
    main()
