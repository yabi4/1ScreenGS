"""Stage 2: locate and classify every piece of code that touches POWCNT1 bit 15.

POWCNT1 (0x04000304) bit 15 is the DS display swap:
    1 = 2D engine A -> upper LCD   (stock for the overworld / battle scene)
    0 = 2D engine A -> lower LCD   (i.e. engine B, the touch UI, goes to the top)

POWCNT1 cannot be reached with a small immediate offset (ARM STRH imm is 8-bit,
Thumb 5-bit; 0x304 exceeds both), so its address always sits in a literal pool.
We find those literals, find the PC-relative LDRs referencing them, then decode
the following instructions to see what is done to bit 15.

The compiler builds the 0x8000 mask by shifting the address register itself:
    0x04000304 >> 11 == 0x8000
so `lsrs rD, rAddr, #11` is the tell-tale sign of a display-swap site.
"""

import json
import pathlib
import struct
import sys
from collections import Counter

ROOT = pathlib.Path(__file__).resolve().parent.parent

POWCNT1 = 0x04000304
SWAP_BIT = 0x8000


def modules(code):
    d = ROOT / "build" / code
    meta = json.loads((d / "modules.json").read_text())
    yield "arm9", meta["arm9"]["ram"], (d / meta["arm9"]["file"]).read_bytes()
    for ovid, ov in sorted(meta["overlays"].items(), key=lambda kv: int(kv[0])):
        yield f"ov{int(ovid):03d}", ov["ram"], (d / ov["file"]).read_bytes()


def find_literals(data, value):
    target = struct.pack("<I", value)
    out, start = [], 0
    while True:
        i = data.find(target, start)
        if i < 0:
            return out
        if i % 4 == 0:
            out.append(i)
        start = i + 1


def thumb_ldr_refs(data, lit_off):
    hits = []
    lo = max(0, lit_off - 0x400 - 4)
    for off in range(lo, lit_off, 2):
        h = struct.unpack_from("<H", data, off)[0]
        if (h & 0xF800) != 0x4800:
            continue
        if ((off + 4) & ~3) + (h & 0xFF) * 4 == lit_off:
            hits.append((off, (h >> 8) & 0x7))
    return hits


def arm_ldr_refs(data, lit_off):
    hits = []
    lo = max(0, lit_off - 0x1000 - 8)
    for off in range(lo, lit_off, 4):
        w = struct.unpack_from("<I", data, off)[0]
        if (w & 0x0F7F0000) != 0x051F0000:
            continue
        imm = w & 0xFFF
        if off + 8 + (imm if (w >> 23) & 1 else -imm) == lit_off:
            hits.append((off, (w >> 12) & 0xF))
    return hits


def classify_thumb(data, off, addr_reg, window=32):
    """Decode forward from the LDR and describe what happens to bit 15."""
    mask_regs = {}          # reg -> constant value it holds
    op = None
    for i in range(1, window):
        p = off + i * 2
        if p + 2 > len(data):
            break
        h = struct.unpack_from("<H", data, p)[0]

        # LSRS rD, rS, #imm5  -> 0000 1 imm5 rs rd
        if (h & 0xF800) == 0x0800:
            imm, rs, rd = (h >> 6) & 0x1F, (h >> 3) & 7, h & 7
            if rs == addr_reg and imm == 11:
                mask_regs[rd] = SWAP_BIT
            continue

        # LDR rD, [pc, #imm8*4] -> literal constant
        if (h & 0xF800) == 0x4800:
            lit = ((p + 4) & ~3) + (h & 0xFF) * 4
            if lit + 4 <= len(data):
                mask_regs[(h >> 8) & 7] = struct.unpack_from("<I", data, lit)[0]
            continue

        # MOVS rD, #imm8
        if (h & 0xF800) == 0x2000:
            mask_regs[(h >> 8) & 7] = h & 0xFF
            continue

        # ALU rD, rS  (0100 00 op rs rd)
        if (h & 0xFC00) == 0x4000:
            alu, rs, rd = (h >> 6) & 0xF, (h >> 3) & 7, h & 7
            names = {0x1: "eor", 0x8: "tst", 0xC: "orr", 0xE: "bic", 0x0: "and"}
            if alu in names:
                val = mask_regs.get(rs)
                if val is not None and (val & SWAP_BIT or val == ~SWAP_BIT & 0xFFFF):
                    op = names[alu]
                elif mask_regs.get(rd) == SWAP_BIT:
                    op = names[alu]
            continue

        # STRH rD, [rB, #imm5*2]  -> commit
        if (h & 0xF800) == 0x8000:
            rb = (h >> 3) & 7
            if rb == addr_reg:
                return {"orr": "SET  (engine A -> TOP, stock)",
                        "bic": "CLEAR (engine A -> BOTTOM, swapped)",
                        "and": "CLEAR (engine A -> BOTTOM, swapped)",
                        "eor": "TOGGLE",
                        }.get(op, "write, bit15 untouched")
    return "no store found"


def main(code="ipgf", verbose=False):
    rows, tally = [], Counter()
    for name, ram, data in modules(code):
        for lit in find_literals(data, POWCNT1):
            for off, rd in thumb_ldr_refs(data, lit):
                kind = classify_thumb(data, off, rd)
                tally[kind] += 1
                rows.append((name, ram + off, "thumb", kind))
            for off, rd in arm_ldr_refs(data, lit):
                tally["arm (LCD power / other)"] += 1
                rows.append((name, ram + off, "arm", "arm (LCD power / other)"))

    interesting = [r for r in rows if "CLEAR" in r[3] or "TOGGLE" in r[3]]

    print(f"=== {code}: {len(rows)} POWCNT1 reference sites ===")
    for kind, n in tally.most_common():
        print(f"  {n:>4}  {kind}")

    print(f"\n=== sites that put engine B (touch UI) on the TOP screen ===")
    if not interesting:
        print("  none - the game only ever asserts the stock routing.")
    for name, addr, mode, kind in interesting:
        print(f"  {name:<7} {addr:#010x} {mode:<5} {kind}")

    if verbose:
        print("\n=== all sites ===")
        for name, addr, mode, kind in rows:
            print(f"  {name:<7} {addr:#010x} {mode:<5} {kind}")

    (ROOT / "symbols" / f"{code}_powcnt.json").write_text(json.dumps(
        [{"module": n, "addr": a, "mode": m, "kind": k} for n, a, m, k in rows], indent=2))
    print(f"\nwrote symbols/{code}_powcnt.json")


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    main(args[0] if args else "ipgf", verbose="-v" in sys.argv)
