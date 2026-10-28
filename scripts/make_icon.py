#!/usr/bin/env python3
"""Builds the Meteora icon sources from one geometry (same as Logo.swift):
- Resources/AppIcon.icon (Icon Composer: pearl-white / gunmetal background)
- Resources/AppIcon.iconset (legacy PNGs for macOS 14-15)
- docs/icon-light.png, docs/icon-dark.png (previews)

The mark: an "M" whose first diagonal arrives as a meteor, a tapering trail
fading from the accent into mother-of-pearl (Amouage Portrayal / Reflection 45).
"""
import json, math, os
from PIL import Image, ImageDraw, ImageFilter

A, B, C, D, E = (392, 802), (392, 390), (580, 620), (768, 390), (768, 802)
STROKE, TAIL = 88, 380
ACCENT, ACCENT_DARK = "#33506B", "#9DB8D3"
BG, BG_DARK = (251, 251, 250), (20, 22, 25)
NACRE = ["#BCD4EC", "#D6CDEE", "#EBC6D6", "#F1E2CC"]
# (offset, colour index or None for the accent, opacity)
STOPS = [(0, None, 1), (0.30, 0, 0.95), (0.55, 1, 0.75), (0.78, 2, 0.45), (1, 3, 0)]

dx, dy = B[0] - C[0], B[1] - C[1]
n = math.hypot(dx, dy)
U = (dx / n, dy / n)
TIP = (B[0] + U[0] * TAIL, B[1] + U[1] * TAIL)

def hexrgb(h):
    h = h.lstrip("#"); return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))

def tail_svg_path():
    r = STROKE / 2; nx, ny = -U[1] * r, U[0] * r
    c1 = (B[0] + nx * .5 + U[0] * TAIL * .55, B[1] + ny * .5 + U[1] * TAIL * .55)
    c2 = (B[0] - nx * .5 + U[0] * TAIL * .55, B[1] - ny * .5 + U[1] * TAIL * .55)
    return (f"M{B[0]+nx:.2f},{B[1]+ny:.2f} Q{c1[0]:.2f},{c1[1]:.2f} {TIP[0]:.2f},{TIP[1]:.2f} "
            f"Q{c2[0]:.2f},{c2[1]:.2f} {B[0]-nx:.2f},{B[1]-ny:.2f} A{r},{r} 0 0 1 {B[0]+nx:.2f},{B[1]+ny:.2f} Z")

def svg(accent):
    stops = "".join(
        f'<stop offset="{o}" stop-color="{accent if c is None else NACRE[c]}" stop-opacity="{a}"/>' for o, c, a in STOPS)
    pts = " ".join(f"{x},{y}" for x, y in (A, B, C, D, E))
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <defs><linearGradient id="t" gradientUnits="userSpaceOnUse" x1="{B[0]}" y1="{B[1]}" x2="{TIP[0]:.2f}" y2="{TIP[1]:.2f}">{stops}</linearGradient></defs>
  <path d="{tail_svg_path()}" fill="url(#t)"/>
  <polyline points="{pts}" fill="none" stroke="{accent}" stroke-width="{STROKE}" stroke-linecap="round" stroke-linejoin="round"/>
</svg>
'''

def stop_color(t, accent):
    for (o0, c0, a0), (o1, c1, a1) in zip(STOPS, STOPS[1:]):
        if o0 <= t <= o1:
            f = (t - o0) / (o1 - o0)
            k0 = hexrgb(accent if c0 is None else NACRE[c0]); k1 = hexrgb(accent if c1 is None else NACRE[c1])
            return tuple(round(k0[i] + (k1[i] - k0[i]) * f) for i in range(3)), a0 + (a1 - a0) * f
    return hexrgb(NACRE[-1]), 0

def draw_glyph(img, accent, k, off):
    """Raster version of the same glyph (k = px per unit, off = origin)."""
    W = img.size[0]
    # tail: march along the axis with shrinking discs (matches the taper)
    tail = Image.new("RGBA", img.size, (0, 0, 0, 0)); td = ImageDraw.Draw(tail)
    steps = 700
    for i in range(steps, -1, -1):
        t = i / steps
        cx, cy = B[0] + U[0] * TAIL * t, B[1] + U[1] * TAIL * t
        r = STROKE / 2 * (1 - t) ** 1.2
        if r * k < 0.3: continue
        col, a = stop_color(t, accent)
        td.ellipse([off[0] + (cx - r) * k, off[1] + (cy - r) * k, off[0] + (cx + r) * k, off[1] + (cy + r) * k], fill=col + (int(255 * a),))
    img.alpha_composite(tail)
    g = Image.new("RGBA", img.size, (0, 0, 0, 0)); d = ImageDraw.Draw(g)
    col = hexrgb(accent) + (255,)
    pts = [A, B, C, D, E]
    for p, q in zip(pts, pts[1:]):
        d.line([(off[0] + p[0] * k, off[1] + p[1] * k), (off[0] + q[0] * k, off[1] + q[1] * k)], fill=col, width=round(STROKE * k))
    for p in pts:
        r = STROKE * k / 2
        d.ellipse([off[0] + p[0] * k - r, off[1] + p[1] * k - r, off[0] + p[0] * k + r, off[1] + p[1] * k + r], fill=col)
    img.alpha_composite(g)

def legacy_icon(size, dark=False):
    """macOS 11-15 style: rounded square on a transparent canvas (824/1024)."""
    S = 4 * size
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    inset = S * 100 / 1024; side = S - 2 * inset; radius = side * 0.2237
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle([inset, inset + S * 0.012, inset + side, inset + side + S * 0.012], radius, fill=(0, 0, 0, 70))
    img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(S * 0.012)))
    bg = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(bg).rounded_rectangle([inset, inset, inset + side, inset + side], radius, fill=(BG_DARK if dark else BG) + (255,))
    img.alpha_composite(bg)
    glyph = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    draw_glyph(glyph, ACCENT_DARK if dark else ACCENT, side / 1024, (inset, inset))
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle([inset, inset, inset + side, inset + side], radius, fill=255)
    img.paste(glyph, (0, 0), Image.composite(glyph, Image.new("RGBA", (S, S)), mask).getchannel("A"))
    return img.resize((size, size), Image.LANCZOS)

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
res = os.path.join(root, "Resources")
with open(os.path.join(res, "AppIcon.icon/Assets/glyph.svg"), "w") as f: f.write(svg(ACCENT))
with open(os.path.join(res, "AppIcon.icon/Assets/glyph-dark.svg"), "w") as f: f.write(svg(ACCENT_DARK))
srgb = lambda c: "srgb:" + ",".join(f"{v / 255:.5f}" for v in c) + ",1.00000"
icon = {
    "fill": {"solid": srgb(BG)},
    "fill-specializations": [{"appearance": "dark", "value": {"solid": srgb(BG_DARK)}}],
    "groups": [{
        "layers": [{
            "image-name-specializations": [{"value": "glyph.svg"}, {"appearance": "dark", "value": "glyph-dark.svg"}],
            "name": "glyph", "glass": False,
            "position": {"scale": 1, "translation-in-points": [0, 0]},
        }],
        "shadow": {"kind": "none", "opacity": 0.5},
        "translucency": {"enabled": False, "value": 0.5},
        "specular": False,
    }],
    "supported-platforms": {"squares": "shared"},
}
with open(os.path.join(res, "AppIcon.icon/icon.json"), "w") as f: json.dump(icon, f, indent=2, ensure_ascii=False)

for base in (16, 32, 128, 256, 512):
    legacy_icon(base).save(os.path.join(res, f"AppIcon.iconset/icon_{base}x{base}.png"))
    legacy_icon(base * 2).save(os.path.join(res, f"AppIcon.iconset/icon_{base}x{base}@2x.png"))
os.makedirs(os.path.join(root, "docs"), exist_ok=True)
legacy_icon(512).save(os.path.join(root, "docs/icon-light.png"))
legacy_icon(512, dark=True).save(os.path.join(root, "docs/icon-dark.png"))
print("ok")
