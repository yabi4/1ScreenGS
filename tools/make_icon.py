"""Draw the application icon: a Poke Ball, gold above and silver below.

Run once; the result is committed. Regenerate with

    python tools/make_icon.py

Gold over silver rather than the usual red says HeartGold and SoulSilver at a
glance, and still reads at 16 pixels, which a two-tone diagonal or a colour per
theme would not. Everything is drawn at 8x and reduced, which is the cheapest
way to get clean edges out of Pillow.
"""

import pathlib
import sys

try:
    from PIL import Image, ImageDraw
except ImportError:
    sys.exit("Pillow is required.  pip install pillow")

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "assets"

GOLD = (251, 211, 146)
GOLD_DEEP = (200, 145, 47)
SILVER = (222, 230, 244)
SILVER_DEEP = (145, 163, 196)
OUTLINE = (28, 28, 32)

SIZES = (256, 128, 64, 48, 32, 16)
SS = 8                                  # supersampling factor


def draw(px: int) -> Image.Image:
    n = px * SS
    img = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    pad = n * 0.03
    box = (pad, pad, n - pad, n - pad)
    ring = max(2, int(n * 0.055))

    # Top half gold, bottom half silver, each with a darker rim for depth.
    d.pieslice(box, 180, 360, fill=GOLD, outline=GOLD_DEEP, width=ring // 2)
    d.pieslice(box, 0, 180, fill=SILVER, outline=SILVER_DEEP, width=ring // 2)
    d.ellipse(box, outline=OUTLINE, width=ring)

    # The band across the middle.
    band = n * 0.055
    d.rectangle((pad, n / 2 - band / 2, n - pad, n / 2 + band / 2), fill=OUTLINE)

    # The button: outer black, white face.
    r_out = n * 0.20
    r_in = n * 0.125
    c = n / 2
    d.ellipse((c - r_out, c - r_out, c + r_out, c + r_out), fill=OUTLINE)
    d.ellipse((c - r_in, c - r_in, c + r_in, c + r_in),
              fill=(255, 255, 255), outline=OUTLINE, width=max(1, ring // 2))

    return img.resize((px, px), Image.LANCZOS)


def main():
    OUT.mkdir(exist_ok=True)
    frames = [draw(px) for px in SIZES]
    ico = OUT / "1screenhgss.ico"
    # Pillow writes every requested size into one .ico, which is what Windows
    # wants: the shell picks 16 or 32, the alt-tab view picks 256.
    frames[0].save(ico, format="ICO",
                   sizes=[(px, px) for px in SIZES])
    png = OUT / "1screenhgss.png"
    frames[0].save(png, format="PNG")
    for f in (ico, png):
        print(f"  wrote {f.relative_to(ROOT)}  ({f.stat().st_size:,} bytes)")


if __name__ == "__main__":
    main()
