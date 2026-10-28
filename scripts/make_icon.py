#!/usr/bin/env python3
"""Builds the Volant icon sources from one geometry (same as Logo.swift):
- Resources/AppIcon.icon (Icon Composer document: white / black background)
- Resources/AppIcon.iconset (legacy PNGs for macOS 14–15)
- docs/icon-light.png, docs/icon-dark.png (previews)
"""
import json, math, os
from PIL import Image, ImageDraw, ImageFilter

V, RT, LT = (512, 772), (724, 268), (300, 268)
W = 92
# Left arm dissolves: (t0, t1, width, offset) dashes, then (t, radius, offset) dots
DASHES = [(0, 0.40, 92, (0, 0)), (0.53, 0.72, 76, (-10, -6))]
DOTS = [(0.87, 32, (-24, -14)), (1.05, 20, (-44, -28))]
GREEN, GREEN_DARK = "#1D5C45", "#5DA683"

def lerp(t):
    return (V[0] + (LT[0] - V[0]) * t, V[1] + (LT[1] - V[1]) * t)

def capsule(p, q, w):
    (x1, y1), (x2, y2) = p, q
    dx, dy = x2 - x1, y2 - y1
    L = math.hypot(dx, dy); nx, ny = -dy / L * w / 2, dx / L * w / 2
    r = w / 2
    return (f"M{x1+nx:.2f},{y1+ny:.2f} L{x2+nx:.2f},{y2+ny:.2f} "
            f"A{r},{r} 0 0 0 {x2-nx:.2f},{y2-ny:.2f} L{x1-nx:.2f},{y1-ny:.2f} "
            f"A{r},{r} 0 0 0 {x1+nx:.2f},{y1+ny:.2f} Z")

def off(p, o):
    return (p[0] + o[0], p[1] + o[1])

def segments():
    segs = [(V, RT, W)] + [(off(lerp(a), o), off(lerp(b), o), w) for a, b, w, o in DASHES]
    dots = [(off(lerp(t), o), r) for t, r, o in DOTS]
    return segs, dots

def svg(color):
    segs, dots = segments()
    paths = "\n".join(f'  <path d="{capsule(p, q, w)}" fill="{color}"/>' for p, q, w in segs)
    circles = "\n".join(f'  <circle cx="{c[0]:.2f}" cy="{c[1]:.2f}" r="{r}" fill="{color}"/>' for c, r in dots)
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">\n{paths}\n{circles}\n</svg>\n')

def draw_glyph(img, color, scale, offset=(0, 0)):
    d = ImageDraw.Draw(img)
    segs, dots = segments()
    ox, oy = offset
    for p, q, w in segs:
        d.line([(ox + p[0]*scale, oy + p[1]*scale), (ox + q[0]*scale, oy + q[1]*scale)], fill=color, width=round(w*scale))
        for e in (p, q):
            r = w * scale / 2
            d.ellipse([ox + e[0]*scale - r, oy + e[1]*scale - r, ox + e[0]*scale + r, oy + e[1]*scale + r], fill=color)
    for c, r0 in dots:
        r = r0 * scale
        d.ellipse([ox + c[0]*scale - r, oy + c[1]*scale - r, ox + c[0]*scale + r, oy + c[1]*scale + r], fill=color)

def legacy_icon(size, dark=False):
    """macOS 11–15 style: rounded square on a transparent canvas (824/1024)."""
    S = 4 * size
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    inset = S * 100 / 1024; side = S - 2 * inset; radius = side * 0.2237
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle([inset, inset + S*0.012, inset + side, inset + side + S*0.012], radius, fill=(0, 0, 0, 70))
    img = Image.alpha_composite(img, shadow.filter(ImageFilter.GaussianBlur(S * 0.012)))
    bg = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(bg).rounded_rectangle([inset, inset, inset + side, inset + side], radius,
                                         fill=(0, 0, 0, 255) if dark else (255, 255, 255, 255))
    img = Image.alpha_composite(img, bg)
    glyph = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    k = side / 1024
    draw_glyph(glyph, GREEN_DARK if dark else GREEN, k, (inset, inset))
    img = Image.alpha_composite(img, glyph)
    return img.resize((size, size), Image.LANCZOS)

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
res = os.path.join(root, "Resources")
with open(os.path.join(res, "AppIcon.icon/Assets/glyph.svg"), "w") as f: f.write(svg(GREEN))
with open(os.path.join(res, "AppIcon.icon/Assets/glyph-dark.svg"), "w") as f: f.write(svg(GREEN_DARK))
icon = {
    "fill": {"solid": "srgb:1.00000,1.00000,1.00000,1.00000"},
    "fill-specializations": [
        {"appearance": "dark", "value": {"solid": "srgb:0.00000,0.00000,0.00000,1.00000"}}
    ],
    "groups": [{
        "layers": [{
            "image-name-specializations": [
                {"value": "glyph.svg"},
                {"appearance": "dark", "value": "glyph-dark.svg"}
            ],
            "name": "glyph",
            "glass": False,
            "position": {"scale": 1, "translation-in-points": [0, 0]}
        }],
        "shadow": {"kind": "none", "opacity": 0.5},
        "translucency": {"enabled": False, "value": 0.5},
        "specular": False
    }],
    "supported-platforms": {"squares": "shared"}
}
with open(os.path.join(res, "AppIcon.icon/icon.json"), "w") as f: json.dump(icon, f, indent=2, ensure_ascii=False)

for base in (16, 32, 128, 256, 512):
    legacy_icon(base).save(os.path.join(res, f"AppIcon.iconset/icon_{base}x{base}.png"))
    legacy_icon(base * 2).save(os.path.join(res, f"AppIcon.iconset/icon_{base}x{base}@2x.png"))
os.makedirs(os.path.join(root, "docs"), exist_ok=True)
legacy_icon(512).save(os.path.join(root, "docs/icon-light.png"))
legacy_icon(512, dark=True).save(os.path.join(root, "docs/icon-dark.png"))
print("ok")
