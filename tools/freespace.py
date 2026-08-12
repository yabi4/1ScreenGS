"""Find padding runs in ARM9 that are free in BOTH IPGF and IPKF.

Our hook code and intent table need a home. ARM9 cannot be grown (overlays load
at 0x021E5920, immediately after ARM9 bss), so we reuse inter-function padding.
A region is only usable if it is padding in both games at the same address.
"""

import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
MIN_RUN = 64


def arm9(code):
    d = ROOT / "build" / code
    meta = json.loads((d / "modules.json").read_text())
    return meta["arm9"]["ram"], (d / meta["arm9"]["file"]).read_bytes()


def runs(data, ram, fill):
    out, start = [], None
    for i, b in enumerate(data):
        if b == fill:
            if start is None:
                start = i
        else:
            if start is not None and i - start >= MIN_RUN:
                out.append((ram + start, i - start))
            start = None
    if start is not None and len(data) - start >= MIN_RUN:
        out.append((ram + start, len(data) - start))
    return out


def main():
    ram_a, a = arm9("ipgf")
    ram_b, b = arm9("ipkf")

    for fill in (0x00, 0xFF):
        ra = {addr: n for addr, n in runs(a, ram_a, fill)}
        rb = {addr: n for addr, n in runs(b, ram_b, fill)}
        common = []
        for addr, n in ra.items():
            if addr in rb:
                common.append((addr, min(n, rb[addr])))
        common.sort(key=lambda r: -r[1])
        print(f"\n=== fill {fill:#04x}: {len(ra)} runs in SS, {len(rb)} in HG, "
              f"{len(common)} at identical addresses (>= {MIN_RUN} bytes) ===")
        for addr, n in common[:15]:
            print(f"  {addr:#010x}  {n:>6} bytes")
        if common:
            total = sum(n for _, n in common)
            print(f"  total usable: {total} bytes across {len(common)} regions")


if __name__ == "__main__":
    main()
