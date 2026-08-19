"""List calls that cross from one module into another module's RAM range.

Overlays call into each other by absolute address, so a BL from ov12 landing
inside ov10's range marks exactly where the battle system hands control to the
action-select / AI overlay.

    python scripts/crossrefs.py --from ov012 --to 10
    python scripts/crossrefs.py --to 10          # from anywhere
"""

import argparse
import json
import pathlib
import struct

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
    ap.add_argument("--from", dest="src", default=None)
    ap.add_argument("--to", type=int, required=True)
    args = ap.parse_args()

    meta = json.loads((ROOT / "build" / args.code / "modules.json").read_text())
    ov = meta["overlays"][str(args.to)]
    lo, hi = ov["ram"], ov["ram"] + ov["dec_size"]
    print(f"target overlay {args.to}: {lo:#010x}..{hi:#010x}\n")

    total = 0
    for name, ram, data in modules(args.code):
        if args.src and name != args.src:
            continue
        # A module that loads at the same base as the target would alias it.
        if name != "arm9" and ram == lo:
            continue
        hits = []
        for off in range(0, len(data) - 3, 2):
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
            if lo <= target < hi:
                hits.append((ram + off, target))
        if hits:
            total += len(hits)
            print(f"[{name}] {len(hits)} call(s) into overlay {args.to}:")
            for site, target in hits:
                print(f"    {site:#010x}  ->  {target:#010x}")
    print(f"\n{total} cross-module call(s) total")


if __name__ == "__main__":
    main()
