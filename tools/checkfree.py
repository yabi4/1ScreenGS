"""Validate candidate free-space regions in ARM9.

A zero run is only safe to overwrite if nothing points into it. Two checks:
  1. Context: show the bytes on either side so we can tell inter-function
     padding from a zero-filled data array or a string-table gap.
  2. References: scan every module for any 32-bit word landing inside the
     region, and for any BL/BLX targeting it.
"""

import json
import pathlib
import struct
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

CANDIDATES = [
    (0x020FEE3D, 401),
    (0x020FEA49, 369),
    (0x020FE8B6, 344),
    (0x02108D98, 300),
    (0x020FECC3, 257),
    (0x021028FC, 112),
    (0x021035A4, 112),
    (0x02110278, 76),
]


def modules(code):
    d = ROOT / "build" / code
    meta = json.loads((d / "modules.json").read_text())
    yield "arm9", meta["arm9"]["ram"], (d / meta["arm9"]["file"]).read_bytes()
    for ovid, ov in sorted(meta["overlays"].items(), key=lambda kv: int(kv[0])):
        yield f"ov{int(ovid):03d}", ov["ram"], (d / ov["file"]).read_bytes()


def show_context(data, ram, addr, size):
    off = addr - ram
    before = data[max(0, off - 24):off]
    after = data[off + size:off + size + 24]

    def fmt(bs):
        hexs = " ".join(f"{b:02x}" for b in bs)
        txt = "".join(chr(b) if 32 <= b < 127 else "." for b in bs)
        return f"{hexs}  |{txt}|"

    print(f"    before: {fmt(before)}")
    print(f"    after : {fmt(after)}")


def main(code="ipgf"):
    mods = list(modules(code))
    arm9_ram, arm9 = mods[0][1], mods[0][2]

    for addr, size in CANDIDATES:
        lo, hi = addr, addr + size
        print(f"\n=== {addr:#010x} .. {hi:#010x} ({size} bytes) ===")
        show_context(arm9, arm9_ram, addr, size)

        pointers = []
        for name, ram, data in mods:
            for off in range(0, len(data) - 3, 4):
                v = struct.unpack_from("<I", data, off)[0]
                if lo <= v < hi:
                    pointers.append((name, ram + off, v))
                    if len(pointers) > 6:
                        break
            if len(pointers) > 6:
                break
        if pointers:
            print(f"    !! {len(pointers)}+ word(s) point into this region:")
            for name, site, v in pointers[:6]:
                print(f"       {name} {site:#010x} -> {v:#010x}")
        else:
            print("    OK: no 32-bit word in any module points into this region")


if __name__ == "__main__":
    main(*sys.argv[1:])
