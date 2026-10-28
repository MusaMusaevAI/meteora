#!/usr/bin/env python3
"""DMG window background (1x and 2x) in the app's style."""
import os
from PIL import Image, ImageDraw, ImageFont

def font(size, bold=False):
    for p in (["/usr/share/fonts/opentype/inter/Inter-SemiBold.otf"] if bold else ["/usr/share/fonts/opentype/inter/Inter-Regular.otf"]) + \
             ["/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"]:
        if os.path.exists(p):
            return ImageFont.truetype(p, size)
    return ImageFont.load_default()

def serif(size):
    for p in ["/usr/share/fonts/truetype/freefont/FreeSerif.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSerif.ttf"]:
        if os.path.exists(p):
            return ImageFont.truetype(p, size)
    return font(size)

def render(scale):
    W, H = 660 * scale, 420 * scale
    img = Image.new("RGB", (W, H), (250, 249, 245))
    d = ImageDraw.Draw(img)
    s = scale
    def center(text, y, f, fill):
        w = d.textlength(text, font=f)
        d.text(((W - w) / 2, y), text, font=f, fill=fill)
    center("Перетащите Volant в «Программы»", 34 * s, serif(25 * s), (20, 20, 19))
    # arrow between icon slots (app at x=170, Applications at x=490, y=190)
    y = 190 * s
    d.line([(262 * s, y), (390 * s, y)], fill=(29, 92, 69), width=3 * s)
    d.polygon([(398 * s, y), (384 * s, y - 9 * s), (384 * s, y + 9 * s)], fill=(29, 92, 69))
    # first-launch note
    box = [40 * s, 300 * s, 620 * s, 396 * s]
    d.rounded_rectangle(box, radius=12 * s, fill=(255, 255, 255), outline=(230, 227, 216), width=1 * s)
    d.text((58 * s, 314 * s), "Первый запуск", font=font(13 * s, True), fill=(29, 92, 69))
    lines = [
        "macOS спросит, доверяете ли вы приложению. Нажмите «Готово», затем откройте",
        "Системные настройки → Конфиденциальность и безопасность → «Всё равно открыть».",
        "Это нужно один раз. Volant работает без интернета и не собирает данные.",
    ]
    for i, ln in enumerate(lines):
        d.text((58 * s, (336 + i * 18) * s), ln, font=font(12 * s), fill=(90, 89, 84))
    return img

out = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "Resources", "dmg")
os.makedirs(out, exist_ok=True)
render(1).save(os.path.join(out, "background.png"))
render(2).save(os.path.join(out, "background@2x.png"))
