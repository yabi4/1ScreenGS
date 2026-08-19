"""Compare every module between IPGF and IPKF.

If a module is identical (or near-identical) in both games, any symbol we find in
one is valid at the same address in the other, and the HeartGold port costs nothing.
"""

import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent


def load(code):
    d = ROOT / "build" / code
    return json.loads((d / "modules.json").read_text()), d


def diff(a: bytes, b: bytes):
    n = min(len(a), len(b))
    d = sum(1 for i in range(n) if a[i] != b[i]) + abs(len(a) - len(b))
    return d


def main():
    ma, da = load("ipgf")
    mb, db = load("ipkf")

    ids = sorted(set(ma["overlays"]) & set(mb["overlays"]), key=int)
    same_ram = sum(1 for i in ids if ma["overlays"][i]["ram"] == mb["overlays"][i]["ram"])
    same_size = sum(1 for i in ids if ma["overlays"][i]["dec_size"] == mb["overlays"][i]["dec_size"])
    print(f"overlays: {len(ids)}  same RAM base: {same_ram}  same decompressed size: {same_size}")

    print(f"\n{'ov':>4} {'ram':>10} {'size(SS)':>9} {'size(HG)':>9} {'diff bytes':>11} {'%':>7}")
    interesting = []
    for i in ids:
        oa, ob = ma["overlays"][i], mb["overlays"][i]
        a = (da / oa["file"]).read_bytes()
        b = (db / ob["file"]).read_bytes()
        d = diff(a, b)
        pct = 100 * d / max(len(a), 1)
        if d != 0:
            interesting.append((int(i), oa["ram"], len(a), len(b), d, pct))
    for i, ram, la, lb, d, pct in sorted(interesting, key=lambda r: -r[5])[:25]:
        print(f"{i:>4} {ram:#010x} {la:>9} {lb:>9} {d:>11} {pct:>6.2f}%")
    print(f"\n{len(ids) - len(interesting)} overlays are byte-identical between HG and SS.")


if __name__ == "__main__":
    main()
