"""Extract and BLZ-decompress an HGSS ROM into build/<gamecode>/.

Produces:
    arm9.bin        raw (compressed) ARM9 as stored in the ROM
    arm9_dec.bin    BLZ-decompressed ARM9, loads at ramAddress
    arm7.bin        raw ARM7
    overlays/ov_NNN.bin     decompressed overlay bodies
    modules.json    RAM base / size metadata for every module (for xref resolution)
"""

import json
import pathlib
import sys

import ndspy.rom
import ndspy.codeCompression

ROOT = pathlib.Path(__file__).resolve().parent.parent


def _text(v):
    if isinstance(v, (bytes, bytearray)):
        return bytes(v).decode("ascii", "replace")
    return str(v)


def gamecode(rom):
    return _text(rom.idCode)


def unpack(rom_path: pathlib.Path):
    rom = ndspy.rom.NintendoDSRom(rom_path.read_bytes())
    code = gamecode(rom)
    out = ROOT / "build" / code.lower()
    (out / "overlays").mkdir(parents=True, exist_ok=True)

    (out / "arm9.bin").write_bytes(rom.arm9)
    (out / "arm7.bin").write_bytes(rom.arm7)

    # ARM9 is BLZ-compressed in HGSS; decompress the whole blob.
    try:
        arm9_dec = ndspy.codeCompression.decompress(rom.arm9)
    except Exception as exc:  # pragma: no cover - diagnostic path
        print(f"  !! ARM9 decompress failed ({exc}); storing raw")
        arm9_dec = rom.arm9
    (out / "arm9_dec.bin").write_bytes(arm9_dec)

    modules = {
        "gamecode": code,
        "title": _text(rom.name).rstrip("\0 "),
        "arm9": {
            "ram": rom.arm9RamAddress,
            "entry": rom.arm9EntryAddress,
            "raw_size": len(rom.arm9),
            "dec_size": len(arm9_dec),
            "file": "arm9_dec.bin",
        },
        "overlays": {},
    }

    overlays = rom.loadArm9Overlays()
    for ovid in sorted(overlays):
        ov = overlays[ovid]
        data = ov.data  # ndspy decompresses lazily on access
        name = f"ov_{ovid:03d}.bin"
        (out / "overlays" / name).write_bytes(data)
        modules["overlays"][str(ovid)] = {
            "ram": ov.ramAddress,
            "ram_size": ov.ramSize,
            "bss_size": ov.bssSize,
            "file_id": ov.fileID,
            "compressed": bool(ov.compressed),
            "raw_size": ov.compressedSize,
            "dec_size": len(data),
            "file": f"overlays/{name}",
        }

    (out / "modules.json").write_text(json.dumps(modules, indent=2))

    print(f"{code}: arm9 {len(rom.arm9):#x} -> {len(arm9_dec):#x}, "
          f"{len(overlays)} overlays, {len(rom.files)} files -> {out}")
    return out


if __name__ == "__main__":
    targets = sys.argv[1:] or ["roms/ipgf.nds", "roms/ipkf.nds"]
    for t in targets:
        unpack(ROOT / t if not pathlib.Path(t).is_absolute() else pathlib.Path(t))
