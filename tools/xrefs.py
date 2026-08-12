"""Cross-reference tool: who calls a given address?

Scans ARM9 + every overlay for ARM BL/BLX and Thumb BL/BLX and resolves the
target address. Modules all have fixed RAM bases (identical in HG and SS), so
targets resolve unambiguously.

Usage:
    python scripts/xrefs.py 0x0201a200            # callers of an address
    python scripts/xrefs.py 0x0201a200 --code ipkf
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


def calls_in(data, ram):
    """Yield (call_site_ram, target_ram, kind)."""
    n = len(data)

    # Thumb BL / BLX: halfword pair F000-F7FF then F800-FFFF (BL) or E800-EFFF (BLX)
    for off in range(0, n - 3, 2):
        h1 = struct.unpack_from("<H", data, off)[0]
        if (h1 & 0xF800) != 0xF000:
            continue
        h2 = struct.unpack_from("<H", data, off + 2)[0]
        if (h2 & 0xF800) == 0xF800:
            kind, low = "thumb-bl", (h2 & 0x7FF) << 1
        elif (h2 & 0xF800) == 0xE800:
            kind, low = "thumb-blx", (h2 & 0x7FE) << 1
        else:
            continue
        target = ram + off + 4 + (sx(h1 & 0x7FF, 11) << 12) + low
        if kind == "thumb-blx":
            target &= ~3
        yield ram + off, target, kind

    # ARM BL: cond=1110, 1011
    for off in range(0, n - 3, 4):
        w = struct.unpack_from("<I", data, off)[0]
        if (w >> 24) == 0xEB:
            yield ram + off, ram + off + 8 + (sx(w & 0xFFFFFF, 24) << 2), "arm-bl"


def build(code):
    cache = ROOT / "build" / code / "calls.json"
    if cache.exists():
        return json.loads(cache.read_text())
    index = {}
    for name, ram, data in modules(code):
        for site, target, kind in calls_in(data, ram):
            index.setdefault(str(target), []).append([name, site, kind])
    cache.write_text(json.dumps(index))
    return index


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("addr", nargs="*")
    ap.add_argument("--code", default="ipgf")
    ap.add_argument("--rebuild", action="store_true")
    args = ap.parse_args()

    cache = ROOT / "build" / args.code / "calls.json"
    if args.rebuild and cache.exists():
        cache.unlink()
    index = build(args.code)
    print(f"call index for {args.code}: {len(index)} distinct targets")

    for a in args.addr:
        target = int(a, 0)
        # Thumb targets are stored even; accept +1 (thumb bit) too.
        hits = index.get(str(target), []) + index.get(str(target & ~1), [])
        print(f"\n=== callers of {target:#010x} : {len(hits)} ===")
        for name, site, kind in hits:
            print(f"  {name:<7} {site:#010x}  {kind}")


if __name__ == "__main__":
    main()
