"""Read words / disassemble a module by RAM address.

    python scripts/peek.py w 0x02000e64 0x02000e70      # dump words in range
    python scripts/peek.py w 0x02000e64                 # single word
    python scripts/peek.py --code ipkf w 0x02000e64
"""

import argparse
import json
import pathlib
import struct

ROOT = pathlib.Path(__file__).resolve().parent.parent


def load(code):
    d = ROOT / "build" / code
    meta = json.loads((d / "modules.json").read_text())
    mods = [("arm9", meta["arm9"]["ram"], (d / meta["arm9"]["file"]).read_bytes())]
    for ovid, ov in sorted(meta["overlays"].items(), key=lambda kv: int(kv[0])):
        mods.append((f"ov{int(ovid):03d}", ov["ram"], (d / ov["file"]).read_bytes()))
    return mods


def find(mods, addr, prefer=None):
    for name, ram, data in mods:
        if prefer and name != prefer:
            continue
        if ram <= addr < ram + len(data):
            return name, ram, data
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["w"])
    ap.add_argument("start")
    ap.add_argument("end", nargs="?")
    ap.add_argument("--code", default="ipgf")
    ap.add_argument("--module", default="arm9")
    args = ap.parse_args()

    mods = load(args.code)
    start = int(args.start, 0)
    end = int(args.end, 0) if args.end else start + 4

    for addr in range(start, end, 4):
        hit = find(mods, addr, args.module) or find(mods, addr)
        if not hit:
            print(f"{addr:#010x}  <not in any module>")
            continue
        name, ram, data = hit
        v = struct.unpack_from("<I", data, addr - ram)[0]
        print(f"{addr:#010x}  {v:#010x}   [{name}]")


if __name__ == "__main__":
    main()
