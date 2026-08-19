"""Find genuinely dead functions in ARM9.

A gap between two referenced addresses is normally just the body of a live
function, so gap size alone proves nothing. A function is dead only if its
ENTRY POINT is never reached: not a BL/BLX target, and not the value of any
32-bit word in any module (which would be a function-pointer table entry).

We locate entries by their Thumb prologue (`push {..., lr}` = 0xB5xx) preceded
by a function terminator (`pop {..., pc}`, `bx lr`, or a branch), then keep the
ones nothing references. A region qualifies only if it is dead in BOTH games.
"""

import json
import pathlib
import struct

ROOT = pathlib.Path(__file__).resolve().parent.parent

TEXT_LO = 0x02000800
TEXT_HI = 0x020F0000
MIN_SIZE = 96

TERMINATORS = (0x4770,)  # bx lr


def modules(code):
    d = ROOT / "build" / code
    meta = json.loads((d / "modules.json").read_text())
    yield "arm9", meta["arm9"]["ram"], (d / meta["arm9"]["file"]).read_bytes()
    for ovid, ov in sorted(meta["overlays"].items(), key=lambda kv: int(kv[0])):
        yield f"ov{int(ovid):03d}", ov["ram"], (d / ov["file"]).read_bytes()


def referenced(code):
    refs = set()
    index = json.loads((ROOT / "build" / code / "calls.json").read_text())
    for target in index:
        t = int(target)
        if TEXT_LO <= t < TEXT_HI:
            refs.add(t & ~1)
    for _, ram, data in modules(code):
        for off in range(0, len(data) - 3, 4):
            v = struct.unpack_from("<I", data, off)[0]
            if TEXT_LO <= v < TEXT_HI:
                refs.add(v & ~1)
    return refs


def is_terminator(h):
    return h in TERMINATORS or (h & 0xFF00) == 0xBD00 or (h & 0xF800) == 0xE000


def dead_functions(code):
    refs = referenced(code)
    mods = list(modules(code))
    ram, data = mods[0][1], mods[0][2]

    # All plausible function entries, in address order.
    entries = []
    for addr in range(TEXT_LO, TEXT_HI, 2):
        off = addr - ram
        if off + 2 > len(data):
            break
        h = struct.unpack_from("<H", data, off)[0]
        if (h & 0xFF00) == 0xB500:
            prev = struct.unpack_from("<H", data, off - 2)[0] if off >= 2 else 0
            if is_terminator(prev) or prev == 0x0000:
                entries.append(addr)

    boundaries = sorted(set(entries) | refs)
    out = []
    for addr in entries:
        if addr in refs:
            continue
        i = boundaries.index(addr)
        end = boundaries[i + 1] if i + 1 < len(boundaries) else TEXT_HI
        if end - addr >= MIN_SIZE:
            out.append((addr, end - addr))
    return out


def main():
    print("scanning IPGF ...")
    da = {a: n for a, n in dead_functions("ipgf")}
    print("scanning IPKF ...")
    db = {a: n for a, n in dead_functions("ipkf")}

    common = sorted(((a, min(n, db[a])) for a, n in da.items() if a in db),
                    key=lambda r: -r[1])

    print(f"\n=== unreferenced functions present in BOTH games (>= {MIN_SIZE} bytes) ===")
    for a, n in common[:25]:
        print(f"  {a:#010x} {n:>6} bytes")
    print(f"\n{len(common)} common dead functions, {sum(n for _, n in common)} bytes total")


if __name__ == "__main__":
    main()
