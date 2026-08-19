"""Draw the three colour themes side by side for the README.

Each panel carries only its own name, set in the game's own font and rasterised
the same way every in-game label is, so the picture shows the real thing rather
than an impression of it.

    python tools/make_theme_shot.py <rom.nds> [-o docs/img/themes.png]
"""

import argparse
import pathlib
import struct
import sys
import zlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

import ndspy.rom                                      # noqa: E402
from onescreen import labels as L                     # noqa: E402

SCALE = 2                   # DS pixels are small; double them for a readable PNG
PAD = 10                    # breathing room around each panel
GAP = 10                    # between panels
BACKDROP = (248, 248, 250)


def rgb(v):
    """BGR555 to RGB888."""
    return (((v >> 0) & 31) * 255 // 31,
            ((v >> 5) & 31) * 255 // 31,
            ((v >> 10) & 31) * 255 // 31)


def panel(font, name):
    """One themed panel containing `name`, as a grid of RGB tuples."""
    theme = L._use_theme(name)
    codes = _codes_for(theme["label"])
    cell_w = (L._text_width(font, codes) + 8 + 7) // 8
    cols, rows = cell_w + 2, L.SM_CELL_H + 2
    norm = {k: rgb(v) for k, v in L.SM_PAL_NORM_RGB.items()}

    px = [[norm[L.PAPER]] * (cols * 8) for _ in range(rows * 8)]
    for r in range(rows):
        ry = 0 if r == 0 else (2 if r == rows - 1 else 1)
        for c in range(cols):
            cx = 0 if c == 0 else (2 if c == cols - 1 else 1)
            tile = L._frame_tile(**L.FRAME_SHAPES[ry * 3 + cx])
            for y in range(8):
                for x in range(8):
                    px[r * 8 + y][c * 8 + x] = norm.get(tile[y][x], (255, 0, 255))
    strip = L._render_strip(font, codes, cell_w * 8, L.SM_CELL_H * 8)
    for y, line in enumerate(strip):
        for x, v in enumerate(line):
            px[8 + y][8 + x] = norm.get(v, (255, 0, 255))
    return px


def _codes_for(text):
    """The game's character codes for a run of letters."""
    return [478 if ch == " " else 299 + ord(ch) - ord("A") for ch in text.upper()]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("rom")
    ap.add_argument("-o", "--output", default=str(ROOT / "docs" / "img" / "themes.png"))
    args = ap.parse_args()

    rom = ndspy.rom.NintendoDSRom.fromFile(args.rom)
    font = L.Font(L._narc_files(bytes(rom.files[rom.filenames.idOf(L.FONT_NARC)]))[L.FONT_FILE])

    panels = [panel(font, k) for k in ("classic", "heartgold", "soulsilver")]
    ph = max(len(p) for p in panels)
    pw = sum(len(p[0]) for p in panels) + GAP * (len(panels) - 1)
    W, H = (pw + PAD * 2) * SCALE, (ph + PAD * 2) * SCALE

    rows = []
    for y in range(H):
        sy = y // SCALE - PAD
        line = []
        for x in range(W):
            sx = x // SCALE - PAD
            c = BACKDROP
            ox = 0
            for p in panels:
                w = len(p[0])
                if ox <= sx < ox + w and 0 <= sy < len(p):
                    c = p[sy][sx - ox]
                    break
                ox += w + GAP
            line.append(c)
        rows.append(b"\0" + bytes(b for t in line for b in t))

    def chunk(tag, data):
        body = tag + data
        return (struct.pack(">I", len(data)) + body
                + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF))

    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(b"".join(rows), 9))
           + chunk(b"IEND", b""))
    out = pathlib.Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(png)
    print(f"  wrote {out}  ({W}x{H}, {len(png):,} bytes)")


if __name__ == "__main__":
    main()
