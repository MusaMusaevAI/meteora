#!/usr/bin/env python3
"""iPhone app icon (1024×1024, full bleed, no alpha — iOS rounds it) from the
same geometry as make_icon.py, light and dark, into the iOS asset catalog."""
import json, os
from PIL import Image

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
src = open(os.path.join(root, "scripts/make_icon.py")).read()
exec(src[:src.index("root = os.path.dirname")])  # the shared drawing code only

def ios_icon(dark=False, n=1024):
    S = 2 * n
    img = pearl_ground(S, PEARL_DARK if dark else PEARL, 0.25 if dark else 1)
    draw_glyph(img, ACCENT_DARK if dark else ACCENT, S / 1024, (0, 0))
    return img.resize((n, n), Image.LANCZOS).convert("RGB")

out = os.path.join(root, "iOS/Resources/Assets.xcassets/AppIcon.appiconset")
os.makedirs(out, exist_ok=True)
ios_icon().save(os.path.join(out, "icon.png"))
ios_icon(dark=True).save(os.path.join(out, "icon-dark.png"))
json.dump({
    "images": [
        {"filename": "icon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"},
        {"appearances": [{"appearance": "luminosity", "value": "dark"}],
         "filename": "icon-dark.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"},
    ],
    "info": {"author": "xcode", "version": 1},
}, open(os.path.join(out, "Contents.json"), "w"), indent=2)
print("ok")
