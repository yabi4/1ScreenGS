"""Find OverlayManager templates for a given overlay.

HGSS runs its UIs through an app framework whose template is four words:

    struct OverlayManagerTemplate {
        BOOL (*init)(OverlayManager *, int *);
        BOOL (*exec)(OverlayManager *, int *);
        BOOL (*exit)(OverlayManager *, int *);
        FSOverlayID overlayID;
    };

So a template for overlay N is three pointers into overlay N's RAM range followed
by the literal N. Finding it lets us redirect init/exit to our own trampolines
without touching the overlay's code at all.

    python scripts/find_template.py 10
"""

import json
import pathlib
import struct
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent


def modules(code):
    d = ROOT / "build" / code
    meta = json.loads((d / "modules.json").read_text())
    yield "arm9", meta["arm9"]["ram"], (d / meta["arm9"]["file"]).read_bytes()
    for ovid, ov in sorted(meta["overlays"].items(), key=lambda kv: int(kv[0])):
        yield f"ov{int(ovid):03d}", ov["ram"], (d / ov["file"]).read_bytes()


def main():
    target = int(sys.argv[1], 0)
    code = sys.argv[2] if len(sys.argv) > 2 else "ipgf"

    meta = json.loads((ROOT / "build" / code / "modules.json").read_text())
    ov = meta["overlays"][str(target)]
    lo, hi = ov["ram"], ov["ram"] + ov["dec_size"]
    print(f"overlay {target}: RAM {lo:#010x}..{hi:#010x}\n")

    def in_ov(w):
        return lo <= (w & ~1) < hi

    found = 0
    for name, ram, data in modules(code):
        for off in range(0, len(data) - 15, 4):
            w = struct.unpack_from("<4I", data, off)
            if w[3] != target:
                continue
            # init and exit must point into the overlay; exec often does too,
            # but some apps reuse a shared exec, so require at least two hits.
            hits = sum(1 for x in w[:3] if in_ov(x))
            if hits < 2:
                continue
            found += 1
            print(f"[{name}] template at {ram + off:#010x}")
            for i, label in enumerate(("init", "exec", "exit")):
                mark = "" if in_ov(w[i]) else "   (outside overlay)"
                print(f"    {label}: {w[i]:#010x}{mark}")
            print(f"    overlayID: {w[3]}")
    if not found:
        print("no template found - the struct layout may differ")


if __name__ == "__main__":
    main()
