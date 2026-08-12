"""Turn a stock HeartGold/SoulSilver dump into a single-screen build.

Everything happens in memory: the ROM is unpacked, the ARM9 and overlays are
BLZ-decompressed, the display-routing sites are found and rewritten, the ITCM
payload is injected, and the result is repacked.

Patched modules are stored **uncompressed** (`compressed_static_end = 0` for the
ARM9, compression flag cleared for overlays). Both are standard, reversible
transforms; they cost ~300 KB of the ~7.5 MB of free ROM space and avoid any BLZ
recompression risk.
"""

import hashlib
import json
import pathlib
import struct

import ndspy.code
import ndspy.codeCompression
import ndspy.rom

from . import inject, regions, sites, table

PAYLOAD_DIR = pathlib.Path(__file__).resolve().parent / "payload"

# Dumps this has been built and tested against. Anything else still patches, but
# is reported as unverified rather than silently trusted.
KNOWN = {
    "IPGF": ("Pokemon Version Argent SoulSilver (France)",
             "6ed98d446eb65861c71fc5f94bdc35691667f665"),
    "IPKF": ("Pokemon Version Or HeartGold (France)",
             "dba64620a959d5f69ed1cf3e43fcfcf2786d417e"),
    "IPKE": ("Pokemon HeartGold Version (USA)",
             "4fcded0e2713dc03929845de631d0932ea2b5a37"),
}

# Regions sharing the same code layout. HG/SS FR were measured byte-identical in
# ARM9 length and overlay RAM bases, and 114 of 129 overlays are identical, so
# the same edits apply. Other languages are untested - the scanner finds sites by
# instruction shape, so they may well work, but nothing is promised.
SUPPORTED_PREFIXES = ("IPG", "IPK")


def _text(v):
    return bytes(v).decode("ascii", "replace") if isinstance(v, (bytes, bytearray)) else str(v)


def load_payload():
    meta = json.loads((PAYLOAD_DIR / "hook.json").read_text())
    # Addresses are stored as hex strings so they stay readable and cannot be
    # mistyped as decimal.
    meta["load_addr"] = int(meta["load_addr"], 16)
    meta["symbols"] = {k: int(v, 16) for k, v in meta["symbols"].items()}
    return (PAYLOAD_DIR / "hook.bin").read_bytes(), meta


def identify(rom_bytes: bytes):
    """Return (gamecode, title, known_name_or_None, sha1)."""
    rom = ndspy.rom.NintendoDSRom(rom_bytes)
    code = _text(rom.idCode)
    sha1 = hashlib.sha1(rom_bytes).hexdigest()
    known = KNOWN.get(code)
    return code, _text(rom.name).rstrip("\0 "), known, sha1


def patch(rom_bytes: bytes, log=print, auto_battle=True):
    """Return the patched ROM image."""
    code, title, known, sha1 = identify(rom_bytes)
    log(f"  ROM      : {title}  [{code}]")
    log(f"  SHA-1    : {sha1}")

    if not code.startswith(SUPPORTED_PREFIXES):
        raise SystemExit(
            f"{code} is not a Pokemon HeartGold/SoulSilver ROM. This patch only "
            "targets HGSS (game codes IPKx / IPGx).")
    if known and sha1 == known[1]:
        log(f"  Verified : {known[0]}")
    elif known:
        log(f"  WARNING  : {code} recognised but the SHA-1 does not match the "
            "tested dump. Continuing anyway; report problems.")
    else:
        log(f"  NOTE     : {code} has not been tested (only IPGF/IPKF have). "
            "The scanner works by instruction shape, so this may still be fine.")

    rom = ndspy.rom.NintendoDSRom(rom_bytes)

    arm9 = bytearray(ndspy.codeCompression.decompress(rom.arm9))
    inject.check_module_params(arm9)

    overlays = rom.loadArm9Overlays()
    modules = [("arm9", 0x02000000, bytes(arm9))]
    ov_data = {}
    for ovid, ov in sorted(overlays.items()):
        ov_data[ovid] = bytearray(ov.data)
        modules.append((f"ov{ovid:03d}", ov.ramAddress, bytes(ov_data[ovid])))

    found = sites.find(modules)
    chosen, skipped = [], []
    for s in found:
        if table.intent_for(s["module"], s["addr"]) == table.FLIP:
            chosen.append(s)
        else:
            skipped.append(s)

    log(f"  Sites    : {len(found)} found, {len(chosen)} flipped, {len(skipped)} left alone")
    for s in skipped:
        log(f"             skip {s['module']:<7} {s['addr']:#010x} "
            f"[{table.intent_for(s['module'], s['addr'])}] {table.describe(s['module'])}")

    by_module = {}
    for s in chosen:
        by_module.setdefault(s["module"], []).append(s)

    sites.apply(arm9, by_module.get("arm9", []))
    inject.set_uncompressed(arm9)

    payload, meta = load_payload()
    if auto_battle:
        values, delta = regions.resolve(arm9, overlays)

        # Take over these apps' exec pointers in their OverlayManagerTemplates,
        # so the hook is handed &proc_state - the screen level - every frame
        # instead of having to find the manager in RAM. The templates live in
        # ARM9 static data and are located by shape, so this is region-neutral.
        for label, ovy_id, field, symbol, effect in (
                ("Pokedex", 18, "dex_exec_orig", "OneScreen_DexExec",
                 "area map will stay on the bottom screen"),
                ("PC box", 14, "pc_exec_orig", "OneScreen_PcExec",
                 "box screens will stay on the bottom screen"),
                ("Fly map", 101, "map_exec_orig", "OneScreen_MapExec",
                 "the flight animation will stay on the bottom screen"),
                ("Oak", 53, "oak_exec_orig", "OneScreen_OakExec",
                 "the opening speech will stay inverted")):
            tmpl = regions.find_overlay_template(arm9, overlays, ovy_id)
            if tmpl:
                tmpl_addr, _init, orig_exec, _exit = tmpl
                values[field] = orig_exec
                struct.pack_into("<I", arm9, (tmpl_addr + 4) - 0x02000000,
                                 meta["symbols"][symbol] | 1)
                log(f"  {label:<9}: template {tmpl_addr:#010x}, exec "
                    f"{orig_exec:#010x} -> {symbol}")
            else:
                values[field] = 0
                log(f"  {label:<9}: template not found; {effect}")
        payload = inject.fill_config(payload, meta["symbols"]["OneScreen_Config"],
                                     meta["load_addr"], values)

        apps = regions.check_app_table(arm9)
        payload = inject.fill_app_table(payload,
                                        meta["symbols"]["OneScreen_AppTable"],
                                        meta["load_addr"], apps)
        for name, callback, _swap, ok in apps:
            log(f"  App      : {name:<12} {callback:#010x} "
                + ("verified" if ok else
                   "CODE DOES NOT MATCH - entry dropped, this app will not swap"))
        inject.patch_main_loop(arm9, meta["symbols"]["OneScreen_Frame"])
        arm9 = inject.add_autoload_block(arm9, payload, meta["load_addr"])
        log(f"  ITCM     : {len(payload)} bytes at {meta['load_addr']:#010x} "
            f"(payload v{meta['payload_version']}), main loop "
            f"{inject.MAIN_LOOP_SITE:#010x} hooked")
        log(f"  Region   : data shifted {delta:+#x} from the French reference")
        for name in inject.CONFIG_FIELDS:
            log(f"             {name:<15} {values[name]:#010x}")
    else:
        log("  ITCM     : skipped (--no-hook): static screen flips only")

    rom.arm9 = bytes(arm9)

    touched = []
    for ovid, ov in sorted(overlays.items()):
        picks = by_module.get(f"ov{ovid:03d}")
        if not picks:
            continue
        buf = ov_data[ovid]
        sites.apply(buf, picks)
        ov.data = bytes(buf)
        ov.compressed = False
        rom.files[ov.fileID] = ov.save(compress=False)
        touched.append(ovid)
    rom.arm9OverlayTable = ndspy.code.saveOverlayTable(overlays)
    log(f"  Overlays : {len(touched)} rewritten, stored uncompressed")

    return bytes(rom.save())
