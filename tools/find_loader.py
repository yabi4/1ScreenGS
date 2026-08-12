"""Find the overlay load/unload functions by argument-shape heuristics.

An overlay loader is called from all over the game with a different overlay ID
each time. So: for every BL target, collect the set of distinct constants loaded
into r0 just before the call. The loader stands out as the function called with
by far the widest variety of small constants.

    python scripts/find_loader.py
    python scripts/find_loader.py --want 10     # only targets ever called with 10
"""

import argparse
import json
import pathlib
import struct
from collections import defaultdict

ROOT = pathlib.Path(__file__).resolve().parent.parent


def modules(code):
    d = ROOT / "build" / code
    meta = json.loads((d / "modules.json").read_text())
    yield "arm9", meta["arm9"]["ram"], (d / meta["arm9"]["file"]).read_bytes()
    for ovid, ov in sorted(meta["overlays"].items(), key=lambda kv: int(kv[0])):
        yield f"ov{int(ovid):03d}", ov["ram"], (d / ov["file"]).read_bytes()


def sx(v, bits):
    m = 1 << (bits - 1)
    return (v ^ m) - m


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--code", default="ipgf")
    ap.add_argument("--want", type=int, default=None)
    ap.add_argument("--top", type=int, default=12)
    args = ap.parse_args()

    consts = defaultdict(set)     # bl target -> set of r0 constants
    calls = defaultdict(int)

    for name, ram, data in modules(args.code):
        n = len(data)
        for off in range(0, n - 3, 2):
            h1 = struct.unpack_from("<H", data, off)[0]
            if (h1 & 0xF800) != 0xF000:
                continue
            h2 = struct.unpack_from("<H", data, off + 2)[0]
            if (h2 & 0xF800) == 0xF800:
                low = (h2 & 0x7FF) << 1
            elif (h2 & 0xF800) == 0xE800:
                low = (h2 & 0x7FE) << 1
            else:
                continue
            target = (ram + off + 4 + (sx(h1 & 0x7FF, 11) << 12) + low) & ~1
            calls[target] += 1

            # look back a few halfwords for `movs r0, #imm8`
            for back in range(1, 4):
                p = off - back * 2
                if p < 0:
                    break
                h = struct.unpack_from("<H", data, p)[0]
                if (h & 0xFF00) == 0x2000:          # movs r0, #imm8
                    consts[target].add(h & 0xFF)
                    break
                if (h & 0xF800) == 0xF000:          # ran into another BL
                    break

    ranked = sorted(consts.items(), key=lambda kv: -len(kv[1]))
    if args.want is not None:
        ranked = [(t, c) for t, c in ranked if args.want in c]

    print(f"{'target':>12} {'calls':>6} {'distinct r0':>12}  sample constants")
    for target, c in ranked[:args.top]:
        sample = ", ".join(str(x) for x in sorted(c)[:16])
        print(f"  {target:#010x} {calls[target]:>6} {len(c):>12}  {sample}")


if __name__ == "__main__":
    main()
