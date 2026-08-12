"""Find and rewrite the code that decides which screen goes on top.

The DS has two independent 2D engines. `POWCNT1` bit 15 chooses which one drives
the upper LCD:

    1 = engine A -> upper screen    0 = engine A -> lower screen

HGSS asserts this itself in ~90 places, once per app, which is why an external
emulator swap does not survive a screen change. POWCNT1 cannot be reached with a
small immediate offset (ARM STRH imm is 8-bit, Thumb 5-bit, and 0x304 exceeds
both), so its address always sits in a literal pool - which makes every use site
findable.

Apps come in two families, because an app may draw its interactive UI on either
engine and then route that engine to the bottom:

  SET  UI on engine B; the app SETS bit 15 so engine A (decoration) goes on top.
           ldrh rV,[rA] / lsrs rM,rA,#11 / orrs rM,rV / strh rM,[rA]
       The 0x8000 mask is built by shifting the address register itself, since
       0x04000304 >> 11 == 0x8000.
       Flip -> clear bit 15:  bics rV,rM  +  strh rV,[rA]

  CLR  UI on engine A; the app CLEARS bit 15 so engine A lands on the bottom.
           ldr rM,=0xFFFF7FFF / ldrh rV,[rA] / ands rM,rV / strh ...
       Flip -> set bit 15: rewrite the literal to 0x00008000 and turn the AND
       into an ORR, giving `current | 0x8000`.

Both flips are tiny in-place edits; neither needs new code or free space.
"""

import struct

POWCNT1 = 0x04000304
SWAP_BIT = 0x8000
CLEAR_MASK = 0xFFFF7FFF          # ~0x8000, as stored in the literal pool

FAMILY_SET = "SET"
FAMILY_CLR = "CLR"


def _literals(data, value):
    target = struct.pack("<I", value)
    out, start = [], 0
    while True:
        i = data.find(target, start)
        if i < 0:
            return out
        if i % 4 == 0:
            out.append(i)
        start = i + 1


def _ldr_literal_target(data, off):
    """If a Thumb LDR-literal sits at `off`, return (register, literal offset)."""
    if off + 2 > len(data):
        return None
    h = struct.unpack_from("<H", data, off)[0]
    if (h & 0xF800) != 0x4800:
        return None
    return (h >> 8) & 7, ((off + 4) & ~3) + (h & 0xFF) * 4


def _refs_to_literal(data, lit_off, limit=None):
    hits = []
    lo = max(0, lit_off - 0x404)
    hi = min(len(data) - 1, lit_off + 4)
    for off in range(lo, hi, 2):
        r = _ldr_literal_target(data, off)
        if r and r[1] == lit_off:
            hits.append((off, r[0]))
            if limit and len(hits) >= limit:
                break
    return hits


def _analyse(data, ldr_off, ra, window=28):
    """Decode forward from the POWCNT1 LDR and build a patch descriptor."""
    mask_shift_reg = None
    mask_lit = {}
    alu = None

    for i in range(1, window):
        p = ldr_off + i * 2
        if p + 2 > len(data):
            return None
        h = struct.unpack_from("<H", data, p)[0]

        # LSRS rD, rA, #11 -> builds 0x8000 from the address register
        if (h & 0xF800) == 0x0800 and ((h >> 6) & 0x1F) == 11 and ((h >> 3) & 7) == ra:
            mask_shift_reg = h & 7
            continue

        lit = _ldr_literal_target(data, p)
        if lit:
            reg, lit_off = lit
            if lit_off + 4 <= len(data):
                mask_lit[reg] = (lit_off, struct.unpack_from("<I", data, lit_off)[0])
            continue

        if (h & 0xFFC0) in (0x4000, 0x4300):        # ANDS / ORRS rD, rS
            alu = (p, h & 0xFFC0, h & 7, (h >> 3) & 7)
            continue

        if (h & 0xF800) == 0x8000:                  # STRH rD, [rB, #imm]
            rb, rd, imm = (h >> 3) & 7, h & 7, (h >> 6) & 0x1F
            # The compiler interleaves unrelated stores into these sequences;
            # only a store through the POWCNT1 register ends one.
            if rb != ra:
                continue
            if imm != 0 or alu is None:
                return None
            alu_off, alu_op, ad, as_ = alu
            if ad != rd:
                return None

            if alu_op == 0x4300 and mask_shift_reg in (ad, as_):
                value_reg = as_ if ad == mask_shift_reg else ad
                return {
                    "family": FAMILY_SET,
                    "patches": [
                        (alu_off, 2, 0x4380 | (mask_shift_reg << 3) | value_reg),
                        (p, 2, 0x8000 | (ra << 3) | value_reg),
                    ],
                }

            if alu_op == 0x4000:
                for reg in (ad, as_):
                    if reg in mask_lit and mask_lit[reg][1] == CLEAR_MASK:
                        lit_off, _ = mask_lit[reg]
                        if len(_refs_to_literal(data, lit_off, limit=2)) != 1:
                            return None          # shared literal; leave alone
                        return {
                            "family": FAMILY_CLR,
                            "patches": [
                                (lit_off, 4, SWAP_BIT),
                                (alu_off, 2, 0x4300 | (as_ << 3) | ad),
                            ],
                        }
            return None
    return None


def find(modules):
    """modules: iterable of (name, ram_base, data). Returns site descriptors."""
    out = []
    for name, ram, data in modules:
        for lit in _literals(data, POWCNT1):
            for off, ra in _refs_to_literal(data, lit):
                info = _analyse(data, off, ra)
                if info:
                    info.update(module=name, ram=ram, addr=ram + off)
                    out.append(info)
    return out


def apply(buf, sites):
    for s in sites:
        for off, size, value in s["patches"]:
            struct.pack_into("<H" if size == 2 else "<I", buf, off, value)
    return len(sites)
