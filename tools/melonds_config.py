"""Configure melonDS for automated testing.

Binds keyboard keys (melonDS stores Qt key codes) and lets us switch the screen
layout, so screenshots can show either both screens (for diagnosis) or just the
top screen (what the Steam Deck will actually look like).

    python scripts/melonds_config.py --keys
    python scripts/melonds_config.py --sizing top
    python scripts/melonds_config.py --sizing even
"""

import argparse
import os
import pathlib
import re
import shutil

# The WinGet install location. Override with MELONDS_CONFIG if melonDS lives
# somewhere else, or if you are not on Windows.
CONFIG = pathlib.Path(os.environ.get(
    "MELONDS_CONFIG",
    pathlib.Path(os.environ.get("LOCALAPPDATA", "")) / "Microsoft" / "WinGet"
    / "Packages"
    / "melonDS.melonDS_Microsoft.Winget.Source_8wekyb3d8bbwe" / "melonDS.toml"))

# Qt::Key codes
KEYS = {
    "A": 0x58,            # X
    "B": 0x5A,            # Z
    "X": 0x53,            # S
    "Y": 0x41,            # A
    "L": 0x51,            # Q
    "R": 0x57,            # W
    "Start": 0x01000004,  # Return
    "Select": 0x01000003, # Backspace
    "Up": 0x01000013,
    "Down": 0x01000015,
    "Left": 0x01000012,
    "Right": 0x01000014,
    "HK_SwapScreens": 0x54,  # T
}

# melonDS ScreenSizing: 0 even, 1 emphasize top, 2 emphasize bottom, 3 auto,
#                       4 top only, 5 bottom only
SIZING = {"even": 0, "top": 4, "bottom": 5, "auto": 3}


def patch_section(text, section, pairs):
    """Replace `key = value` lines inside [section] only."""
    lines = text.splitlines()
    start = None
    for i, ln in enumerate(lines):
        if ln.strip() == f"[{section}]":
            start = i
            break
    if start is None:
        raise SystemExit(f"section [{section}] not found")
    end = len(lines)
    for i in range(start + 1, len(lines)):
        if lines[i].startswith("["):
            end = i
            break
    for k, v in pairs.items():
        done = False
        for i in range(start + 1, end):
            if re.match(rf"^{re.escape(k)}\s*=", lines[i]):
                lines[i] = f"{k} = {v}"
                done = True
                break
        if not done:
            lines.insert(end, f"{k} = {v}")
            end += 1
    return "\n".join(lines) + "\n"


def patch_toplevel(text, pairs):
    lines = text.splitlines()
    for k, v in pairs.items():
        for i, ln in enumerate(lines):
            if re.match(rf"^{re.escape(k)}\s*=", ln):
                lines[i] = f"{k} = {v}"
                break
    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--keys", action="store_true")
    ap.add_argument("--sizing", choices=sorted(SIZING))
    ap.add_argument("--gdb", choices=["true", "false"])
    args = ap.parse_args()

    backup = CONFIG.with_suffix(".toml.orig")
    if not backup.exists():
        shutil.copy2(CONFIG, backup)
        print(f"backed up original -> {backup.name}")

    text = CONFIG.read_text(encoding="utf-8")
    if args.keys:
        text = patch_section(text, "Instance0.Keyboard", KEYS)
        print("bound: A=X B=Z X=S Y=A L=Q R=W Start=Return Select=Backspace arrows, SwapScreens=T")
    if args.sizing:
        text = patch_toplevel(text, {"ScreenSizing": SIZING[args.sizing]})
        print(f"ScreenSizing = {args.sizing} ({SIZING[args.sizing]})")
    if args.gdb:
        # The stub needs the JIT off; melonDS ships with it disabled already.
        text = patch_section(text, "Instance0.Gdb", {"Enabled": args.gdb})
        print(f"GDB stub Enabled = {args.gdb} (ARM9 on port 3333)")

    CONFIG.write_text(text, encoding="utf-8")


if __name__ == "__main__":
    main()
