"""统一的字体加载器 —— 所有由脚本绘制的图片都用这一套。

用户要求：「让肥鱼绘制的所有图片字体都变成草莓字体，包括加粗的」。

所以这里只认一个字体文件：

    C:\\Users\\21415\\AppData\\Local\\Microsoft\\Windows\\Fonts\\
        AaCaoKeSongMianBaoYuan-2.ttf      ← 字体名「Aa 草莓可颂面包圆」

它**没有粗体变体**（装饰体基本都是单字重）。所以「加粗」用 Pillow 的
`stroke_width` 描边模拟 —— 这是 Pillow 里唯一能对任意 TTF 做伪粗体的办法，
效果上比几何拉伸（那会把字形拉扁）自然得多。

用法：

    from font_strawberry import font
    f = font(92)            # 常规
    f, stroke = font_bold(92)   # 伪粗体：返回 (字体, 描边宽度)

    d.text((x, y), "DSH 工作台", font=f, fill=..., stroke_width=stroke,
           stroke_fill=同色)
"""

from __future__ import annotations

import os

from PIL import ImageFont

#: 草莓字体（Aa 草莓可颂面包圆）的实际文件位置。
STRAWBERRY = (
    r"C:\Users\21415\AppData\Local\Microsoft\Windows\Fonts"
    r"\AaCaoKeSongMianBaoYuan-2.ttf"
)

#: 万一草莓字体被卸载，退回这些（保证脚本还能跑出图，不会直接崩）。
FALLBACKS = [
    r"C:\Windows\Fonts\msyh.ttc",
    r"C:\Windows\Fonts\msyhbd.ttc",
    r"C:\Windows\Fonts\segoeui.ttf",
]

_cache: dict[tuple[str, int], ImageFont.FreeTypeFont] = {}


def _resolve() -> str | None:
    for p in [STRAWBERRY, *FALLBACKS]:
        if p and os.path.exists(p):
            return p
    return None


def font(size: int) -> ImageFont.FreeTypeFont:
    """按字号取草莓字体。"""
    path = _resolve()
    if path is None:
        return ImageFont.load_default()
    key = (path, int(size))
    f = _cache.get(key)
    if f is None:
        f = ImageFont.truetype(path, int(size))
        _cache[key] = f
    return f


def bold_stroke(size: int) -> int:
    """伪粗体的描边宽度：按字号线性放大，小字至少 1px。"""
    return max(1, round(size * 0.035))


def font_bold(size: int) -> tuple[ImageFont.FreeTypeFont, int]:
    """伪粗体。返回 (字体, stroke_width)，调用处要把 stroke_width 传给 `draw.text`
    并把 `stroke_fill` 设成和 `fill` 一样的颜色。"""
    return font(size), bold_stroke(size)


def draw_text(draw, xy, text, *, size, fill, bold=False, anchor=None, **kw):
    """一行字直接画出来（自动处理伪粗体）。`draw` 是 `ImageDraw.Draw` 实例。"""
    f = font(size)
    stroke = bold_stroke(size) if bold else 0
    if stroke:
        kw.setdefault("stroke_width", stroke)
        kw.setdefault("stroke_fill", fill)
    if anchor:
        kw["anchor"] = anchor
    draw.text(xy, text, font=f, fill=fill, **kw)
    return f


def text_width(draw, text, *, size, bold=False) -> int:
    """量宽度（要和 draw_text 用同一个字体/描边，否则居中会偏）。"""
    f = font(size)
    w = draw.textlength(text, font=f)
    if bold:
        w += bold_stroke(size) * 2
    return int(round(w))
