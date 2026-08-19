"""Toolchain sanity checks (Stage 1 gate).

1. Byte-identical repack: ndspy load -> save must reproduce the original ROM
   exactly. This proves the pack/unpack path without needing an emulator.
2. HG vs SS similarity: how close are the two decompressed ARM9s? Determines how
   cheap the FR HeartGold port will be.
"""

import pathlib

import ndspy.rom

ROOT = pathlib.Path(__file__).resolve().parent.parent


def repack_identical():
    for code in ("ipgf", "ipkf"):
        orig = (ROOT / "roms" / f"{code}.nds").read_bytes()
        out = bytes(ndspy.rom.NintendoDSRom(orig).save())
        same = out == orig
        print(f"{code}: repack {len(out):#x} vs {len(orig):#x}  identical={same}")
        if not same:
            n = min(len(out), len(orig))
            diffs = [i for i in range(n) if out[i] != orig[i]]
            print(f"   {len(diffs)} differing bytes; first: {[hex(d) for d in diffs[:8]]}")


def arm9_similarity():
    a = (ROOT / "build/ipgf/arm9_dec.bin").read_bytes()
    b = (ROOT / "build/ipkf/arm9_dec.bin").read_bytes()
    d = sum(1 for x, y in zip(a, b) if x != y)
    print(f"arm9_dec: len {len(a):#x}/{len(b):#x}  differing {d} bytes ({100 * d / len(a):.3f}%)")

    # Longest common identical runs tell us whether code is at the SAME address.
    runs, cur = [], 0
    for x, y in zip(a, b):
        if x == y:
            cur += 1
        else:
            if cur:
                runs.append(cur)
            cur = 0
    if cur:
        runs.append(cur)
    runs.sort(reverse=True)
    print(f"   identical runs: count={len(runs)} longest={runs[:5]}")


if __name__ == "__main__":
    repack_identical()
    arm9_similarity()
