#!/usr/bin/env python3
"""Genera l'icona dell'app dentro SSDCopier/Assets.xcassets/AppIcon.appiconset.

Il disegno e' vettoriale-ish: viene renderizzato a 4096 px e ridotto con
Lanczos a ogni misura richiesta, cosi' i bordi restano puliti anche a 16 px.

Uso:
    python3 scripts/generate_icon.py

Richiede Pillow:  pip install Pillow
"""

from __future__ import annotations

import json
import os
import sys

try:
    from PIL import Image, ImageDraw, ImageFilter
except ImportError:
    sys.exit("Serve Pillow: pip install Pillow")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICONSET = os.path.join(ROOT, "SSDCopier", "Assets.xcassets", "AppIcon.appiconset")

# Si disegna su una tela sovracampionata e si riduce alla fine.
CANVAS = 1024
SCALE = 4
S = CANVAS * SCALE

# Griglia macOS: la piastra occupa 824 px su 1024, con raggio ~22.5 %.
PLATE_INSET = 100
PLATE_RADIUS = 186

GRADIENT_TOP = (74, 157, 255)
GRADIENT_BOTTOM = (11, 87, 208)
CHECK_GREEN = (52, 199, 89)

# (nome file, lato in px) — le misure che macOS richiede.
OUTPUTS = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

CONTENTS = {
    "images": [
        {"idiom": "mac", "scale": "1x", "size": "16x16", "filename": "icon_16x16.png"},
        {"idiom": "mac", "scale": "2x", "size": "16x16", "filename": "icon_16x16@2x.png"},
        {"idiom": "mac", "scale": "1x", "size": "32x32", "filename": "icon_32x32.png"},
        {"idiom": "mac", "scale": "2x", "size": "32x32", "filename": "icon_32x32@2x.png"},
        {"idiom": "mac", "scale": "1x", "size": "128x128", "filename": "icon_128x128.png"},
        {"idiom": "mac", "scale": "2x", "size": "128x128", "filename": "icon_128x128@2x.png"},
        {"idiom": "mac", "scale": "1x", "size": "256x256", "filename": "icon_256x256.png"},
        {"idiom": "mac", "scale": "2x", "size": "256x256", "filename": "icon_256x256@2x.png"},
        {"idiom": "mac", "scale": "1x", "size": "512x512", "filename": "icon_512x512.png"},
        {"idiom": "mac", "scale": "2x", "size": "512x512", "filename": "icon_512x512@2x.png"},
    ],
    "info": {"author": "xcode", "version": 1},
}


def px(value: float) -> float:
    """Da coordinate su tela 1024 a coordinate sovracampionate."""
    return value * SCALE


def vertical_gradient(size: int, top: tuple[int, int, int], bottom: tuple[int, int, int]) -> Image.Image:
    """Sfumatura verticale disegnata a una colonna e poi allargata."""
    column = Image.new("RGB", (1, size))
    pixels = column.load()
    for y in range(size):
        t = y / max(1, size - 1)
        pixels[0, y] = (
            round(top[0] + (bottom[0] - top[0]) * t),
            round(top[1] + (bottom[1] - top[1]) * t),
            round(top[2] + (bottom[2] - top[2]) * t),
        )
    return column.resize((size, size), Image.Resampling.BILINEAR)


def rounded_mask(size: int, box: tuple[float, float, float, float], radius: float) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius=radius, fill=255)
    return mask


def render_master() -> Image.Image:
    image = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    # 1. La piastra: sfumatura ritagliata con la maschera arrotondata.
    plate_box = (px(PLATE_INSET), px(PLATE_INSET), px(CANVAS - PLATE_INSET), px(CANVAS - PLATE_INSET))
    plate = vertical_gradient(S, GRADIENT_TOP, GRADIENT_BOTTOM).convert("RGBA")
    plate.putalpha(rounded_mask(S, plate_box, px(PLATE_RADIUS)))

    # Ombra morbida sotto la piastra, come nelle icone di sistema.
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        (plate_box[0], plate_box[1] + px(14), plate_box[2], plate_box[3] + px(14)),
        radius=px(PLATE_RADIUS),
        fill=(0, 0, 0, 70),
    )
    image = Image.alpha_composite(image, shadow.filter(ImageFilter.GaussianBlur(px(11))))
    image = Image.alpha_composite(image, plate)

    # 2. Metafora "copia verificata": due quadrati sovrapposti, quello davanti
    #    porta il segno di spunta. Regge la lettura anche a 16 px.
    square = 360.0
    radius = 82.0
    back_origin = (292.0, 292.0)
    front_origin = (372.0, 372.0)

    back = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(back).rounded_rectangle(
        (px(back_origin[0]), px(back_origin[1]),
         px(back_origin[0] + square), px(back_origin[1] + square)),
        radius=px(radius),
        fill=(255, 255, 255, 110),
    )
    image = Image.alpha_composite(image, back)

    # Ombra del quadrato in primo piano, per staccarlo da quello dietro.
    front_shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(front_shadow).rounded_rectangle(
        (px(front_origin[0]), px(front_origin[1] + 10),
         px(front_origin[0] + square), px(front_origin[1] + square + 10)),
        radius=px(radius),
        fill=(0, 0, 0, 90),
    )
    image = Image.alpha_composite(image, front_shadow.filter(ImageFilter.GaussianBlur(px(9))))

    front = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(front).rounded_rectangle(
        (px(front_origin[0]), px(front_origin[1]),
         px(front_origin[0] + square), px(front_origin[1] + square)),
        radius=px(radius),
        fill=(255, 255, 255, 255),
    )
    image = Image.alpha_composite(image, front)

    # 3. Il segno di spunta, in coordinate relative al quadrato davanti.
    def point(fx: float, fy: float) -> tuple[float, float]:
        return (px(front_origin[0] + square * fx), px(front_origin[1] + square * fy))

    check = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(check).line(
        [point(0.25, 0.52), point(0.43, 0.70), point(0.76, 0.31)],
        fill=CHECK_GREEN + (255,),
        width=int(px(46)),
        joint="curve",
    )
    # `joint` non arrotonda le estremita': ci pensano due dischi.
    draw = ImageDraw.Draw(check)
    for fx, fy in ((0.25, 0.52), (0.76, 0.31)):
        cx, cy = point(fx, fy)
        r = px(23)
        draw.ellipse((cx - r, cy - r, cx + r, cy + r), fill=CHECK_GREEN + (255,))

    return Image.alpha_composite(image, check)


def main() -> int:
    os.makedirs(ICONSET, exist_ok=True)
    master = render_master()

    for filename, size in OUTPUTS:
        master.resize((size, size), Image.Resampling.LANCZOS).save(
            os.path.join(ICONSET, filename), "PNG", optimize=True
        )

    with open(os.path.join(ICONSET, "Contents.json"), "w", encoding="utf-8") as handle:
        json.dump(CONTENTS, handle, indent=2)
        handle.write("\n")

    print(f"Generate {len(OUTPUTS)} immagini in {os.path.relpath(ICONSET, ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
