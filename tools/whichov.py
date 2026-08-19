"""Identify which overlay is resident at a shared RAM base.

Several overlays load at the same address (they are mutually exclusive), so a
memory dump alone is ambiguous. Compare the observed words against the stored
image of every overlay that maps to that base.

    python scripts/whichov.py 0x0221BE40 0xb082b5f8 0x20d51c06 0x1c0d9201
"""

import json
import pathlib
import struct
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent


def main():
    base = int(sys.argv[1], 0)
    observed = [int(a, 0) for a in sys.argv[2:]]

    d = ROOT / "build" / "ipgf"
    meta = json.loads((d / "modules.json").read_text())

    candidates = []
    for ovid, ov in sorted(meta["overlays"].items(), key=lambda kv: int(kv[0])):
        if ov["ram"] != base:
            continue
        data = (d / ov["file"]).read_bytes()
        words = [struct.unpack_from("<I", data, i * 4)[0]
                 for i in range(min(len(observed), len(data) // 4))]
        candidates.append((int(ovid), words, ov["dec_size"]))

    print(f"overlays that load at {base:#010x}:")
    for ovid, words, size in candidates:
        match = words[:len(observed)] == observed
        mark = "  <== MATCH" if match else ""
        print(f"  ov{ovid:03d} (size {size:#x}): "
              + " ".join(f"{w:#010x}" for w in words) + mark)
    print("\nobserved:            " + " ".join(f"{w:#010x}" for w in observed))


if __name__ == "__main__":
    main()
