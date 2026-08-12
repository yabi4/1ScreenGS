"""Resolve the addresses the hook needs, per ROM.

Measured across French and US HeartGold:

* ARM9 **code** addresses are **identical**. The same anchors were found at the
  same addresses in both - the display-select helper body at `0x02022D40`, the
  soft-reset check at `0x02000DB8`, the main-loop tail at `0x02000E32` - and the
  name-entry app function at `0x02083140` is byte-identical.
* Only **data, BSS and overlay bases** move, and uniformly: US = FR − 0x20.
  (`static_bss_start`, `bss_end` and every overlay base all shift by the same
  amount, because the US static data section is 0x20 bytes smaller.)

So there is no per-region address table. Everything is derived from the ROM:

* the state block address is read straight out of the main loop's own literal,
  which gives the shift for free;
* the overlay values come from the overlay table.

This means an untested revision either resolves cleanly or fails the sanity
checks - it cannot silently produce a subtly wrong build.
"""

import struct

ARM9_RAM = 0x02000000

# `ldr r4, =<state block>` in the main loop. A CODE address, so identical
# across regions; the literal it points at is what moves.
STATE_BLOCK_LDR = 0x02000DA6
STATE_BLOCK_REG = 4

# What that literal reads in the French ROMs, used only to compute the shift.
FR_STATE_BLOCK = 0x021D112C

PAD_HELD_OFFSET = 0x38          # gSystem.heldKeysRaw
SCREENS_FLIPPED_OFFSET = 0x69   # gSystem.screensFlipped

# The battle phase signal. Found empirically first, then identified with the
# decomp as pret/pokeheartgold's poke_overlay.c:
#
#     typedef struct PMiLoadedOverlay { FSOverlayID id; BOOL active; };
#     static PMiLoadedOverlay sOverlayRegions[OVY_REGION_NUM][OVY_MAX_PER_REGION];
#
# 3 regions x 8 slots x 8 bytes of BSS. The value the hook reads is main-region
# slot 3's overlay id, which the battle drives as it loads a different overlay
# per phase. Being BSS it cannot be found by shape - but exactly one ARM9
# literal points at the array, at a fixed CODE address, so reading that literal
# yields the per-region base. Measured: FR 0x021D0E10, US 0x021D0DF0.
OVERLAY_REGIONS_LITERAL = 0x0200713C
FR_OVERLAY_REGIONS = 0x021D0E10
BATTLE_OVERLAY_SLOT = 3
LOADED_OVERLAY_SIZE = 8         # sizeof(PMiLoadedOverlay)

# sFieldSysPtr, the file-static in pret's field_system.c holding the live
# FieldSystem. The hook reads FieldSystem.unk1C (+0x1C) through it to tell when
# a script has taken over the bottom screen. Also BSS, also unfindable by shape,
# but six ARM9 literals point at it - at the *same six code addresses* in all
# three ROMs, each holding its own region's value. Measured: FR 0x021D4178,
# US 0x021D4158.
FIELD_SYS_LITERAL = 0x0203DEA0
FR_FIELD_SYS = 0x021D4178

# Task_StartMenu, the overworld menu's task function. ARM9 code, so the address
# does not move between regions - the 24-byte prologue is byte-identical in
# IPGF, IPKF and IPKE - but it is checked rather than trusted, and zeroed if the
# code has changed. Zero simply disables the menu-exit check in the hook.
START_MENU_TASK = 0x0203BEF1
START_MENU_TASK_SIG = bytes.fromhex(
    "70b5061c14f0aafb041c301c14f0a8fb051ce98c142900d9")


# app_table in src/hook.s. These are ARM9 *code* addresses, so they do not move
# between regions - but rather than trust that, the patcher checks the bytes at
# each one against the routine it expects and refuses to use an address whose
# code has changed. Each entry is (name, callback, swap, signature).
#
# Name entry is not an OverlayManager application; this is the small routine
# that raises the display flag at 0x021D1195 and calls the shared helper. Its
# 24-byte prologue was measured byte-identical in IPGF, IPKF and IPKE.
# The evolution scene is the same shape: ARM9 code, no POWCNT1 site of its own,
# so it keeps whatever routing it inherits - the menu's, when the evolution was
# triggered from the bag. Its Pokemon and text are on engine A.
APP_TABLE = [
    ("name entry", 0x02083141, 0,
     bytes.fromhex("08b59df76bfa88f76df8034b034901205a581043585008bd")),
    ("evolution", 0x02077271, 0,
     bytes.fromhex("38b5041c75300278201c73300178201c72300078ff231b02")),
]


def check_app_table(arm9: bytes):
    """Return [(name, callback, swap, ok), ...] for the app_table entries."""
    out = []
    for name, callback, swap, sig in APP_TABLE:
        off = (callback & ~1) - ARM9_RAM
        ok = 0 <= off and arm9[off:off + len(sig)] == sig
        out.append((name, callback, swap, ok))
    return out


def _checked(arm9: bytes, addr: int, sig: bytes) -> int:
    """Return addr if the code there still matches, else 0."""
    off = (addr & ~1) - ARM9_RAM
    return addr if 0 <= off and arm9[off:off + len(sig)] == sig else 0


def _read_literal(arm9: bytes, ldr_addr: int, want_reg=None) -> int:
    off = ldr_addr - ARM9_RAM
    h = struct.unpack_from("<H", arm9, off)[0]
    if (h & 0xF800) != 0x4800:
        raise ValueError(f"{ldr_addr:#010x} is not a Thumb LDR-literal "
                         f"(found {h:#06x}) - unexpected ROM layout")
    if want_reg is not None and ((h >> 8) & 7) != want_reg:
        raise ValueError(f"{ldr_addr:#010x} loads r{(h >> 8) & 7}, expected "
                         f"r{want_reg} - unexpected ROM layout")
    lit = ((off + 4) & ~3) + (h & 0xFF) * 4
    return struct.unpack_from("<I", arm9, lit)[0]


def find_overlay_template(arm9: bytes, overlays, ovy_id: int):
    """Locate an OverlayManagerTemplate in ARM9 static data, by shape.

    pret/pokeheartgold:

        struct OverlayManagerTemplate { OverlayFunction init, exec, exit;
                                        FSOverlayID ovy_id; };

    so it is three pointers into the overlay followed by the overlay number.
    Found structurally rather than by address, which makes it region-independent
    (measured: FR 0x020FA268, US 0x020FA284 - exactly one match in each ROM).

    Returns (template_address, init, exec, exit) or None.
    """
    ov = overlays[ovy_id]
    lo, hi = ov.ramAddress, ov.ramAddress + ov.ramSize
    hits = []
    for off in range(0, len(arm9) - 16, 4):
        w = struct.unpack_from("<4I", arm9, off)
        if w[3] != ovy_id:
            continue
        if all(lo <= (x & ~1) < hi for x in w[:3]):
            hits.append((ARM9_RAM + off, w[0], w[1], w[2]))
    if len(hits) != 1:
        return None
    return hits[0]


def resolve(arm9: bytes, overlays) -> tuple[dict, int]:
    """Return (config values, delta) for this ROM."""
    state_block = _read_literal(arm9, STATE_BLOCK_LDR, STATE_BLOCK_REG)
    delta = state_block - FR_STATE_BLOCK

    if not 0x02100000 <= state_block < 0x02200000:
        raise ValueError(f"main-loop state block {state_block:#010x} is out of "
                         "the expected range - unexpected ROM layout")
    if abs(delta) > 0x1000:
        raise ValueError(f"region delta {delta:#x} is implausibly large; refusing "
                         "rather than emit a subtly wrong build")

    # A second, independent measurement of the same shift. Both are BSS, so they
    # must move together; if they disagree the layout is not what we think it is.
    regions_base = struct.unpack_from(
        "<I", arm9, OVERLAY_REGIONS_LITERAL - ARM9_RAM)[0]
    if regions_base - FR_OVERLAY_REGIONS != delta:
        raise ValueError(
            f"sOverlayRegions at {regions_base:#010x} implies a shift of "
            f"{regions_base - FR_OVERLAY_REGIONS:#x}, but the state block implies "
            f"{delta:#x}. Refusing rather than emit a subtly wrong build.")

    field_sys = struct.unpack_from("<I", arm9, FIELD_SYS_LITERAL - ARM9_RAM)[0]
    if field_sys - FR_FIELD_SYS != delta:
        raise ValueError(
            f"sFieldSysPtr at {field_sys:#010x} implies a shift of "
            f"{field_sys - FR_FIELD_SYS:#x}, but the state block implies "
            f"{delta:#x}. Refusing rather than emit a subtly wrong build.")

    ov1, ov12 = overlays[1], overlays[12]
    return {
        "pad_held": state_block + PAD_HELD_OFFSET,
        "app_callback": state_block,
        "field_callback": ov1.ramAddress | 1,          # Thumb
        "ov12_lo": ov12.ramAddress,
        "ov12_hi": ov12.ramAddress + ov12.ramSize,
        "battle_state": regions_base + BATTLE_OVERLAY_SLOT * LOADED_OVERLAY_SIZE,
        "field_sys": field_sys,
        "screens_flipped": state_block + SCREENS_FLIPPED_OFFSET,
        "start_menu_task": _checked(arm9, START_MENU_TASK, START_MENU_TASK_SIG),
    }, delta
