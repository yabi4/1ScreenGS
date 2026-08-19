"""Which display-routing sites to flip, and which to leave alone.

Overlay identities come from pret/pokeheartgold's `main.lsf`, which uses the same
overlay numbering as the retail ROM (verified: ov12 = battle, ov1 = field).

Anything not listed defaults to FLIP - the whole point is that bottom-screen UI
should come to the top, so the exceptions are the interesting part.
"""

FLIP, KEEP, TOUCH = "FLIP", "KEEP", "TOUCH"

# Per-SITE decisions, keyed by the address of the POWCNT1 LDR. These win over the
# per-module table below.
SITE_INTENT = {
    # 0x02022D3C is the game's shared display-select helper: it reads a global
    # flag at 0x021D1195 and applies bit 15. ~90 call sites use it, INCLUDING
    # ov001 (the field). Flipping it inverts the overworld too - verified by
    # building an ARM9-only variant, which put the touch menu fullscreen on top
    # and the world underneath.
    0x02022D3E: KEEP,

    # Boot-time graphics init, called once from NitroMain; establishes the
    # initial routing that the field inherits.
    0x0201A2A2: KEEP,
}

# Overlay identities, for the ones that contain a flippable site.
OVERLAY_NAMES = {
    5: "OVY_5 (unidentified)",
    12: "battle system - commands, HP bars, input, cursors",
    14: "OVY_14 (unidentified)",
    15: "OVY_15 (unidentified)",
    17: "berry pots app",
    18: "pokedex app",
    37: "OVY_37 (unidentified)",
    51: "trainer card - main interface",
    52: "trainer card - signature (stylus drawing)",
    54: "options app",
    56: "OVY_56 (unidentified)",
    57: "battle-related system",
    59: "battle-related system",
    64: "OVY_64 (unidentified)",
    67: "OVY_67 (unidentified)",
    68: "OVY_68 (unidentified)",
    70: "battle-related system",
    71: "OVY_71 (unidentified)",
    72: "battle-related system",
    73: "OVY_73 (unidentified)",
    74: "main menu application",
    80: "battle frontier system",
    82: "OVY_82 (unidentified)",
    83: "OVY_83 (unidentified)",
    85: "OVY_85 (unidentified)",
    86: "OVY_86 (unidentified)",
    87: "OVY_87 (unidentified)",
    98: "OVY_98 (unidentified)",
    100: "pokegear - main interface",
    101: "pokegear - map / phone / radio",
    102: "OVY_102 (unidentified)",
    103: "OVY_103 (unidentified)",
    108: "OVY_108 (unidentified)",
    109: "OVY_109 (unidentified)",
    110: "Ruins of Alph sliding puzzle (stylus)",
    111: "OVY_111 (unidentified)",
    112: "OVY_112 (unidentified)",
    113: "OVY_113 (unidentified)",
    122: "voltorb flip minigame",
}

MODULE_INTENT = {
    # The battle scene must stay on top while a turn resolves. The command menu
    # is swapped in dynamically by the ITCM hook instead - see src/hook.s.
    "ov012": KEEP,

    # Stylus-mandatory: the UI must stay on the physical digitizer (lower LCD).
    "ov052": TOUCH,   # trainer card signature - freehand drawing
    "ov110": TOUCH,   # Ruins of Alph sliding puzzle
}

# Field/overworld overlays. None of them contain a flippable site, which is why
# blanket-flipping the overlays cannot disturb the overworld.
FIELD_OVERLAYS = (1, 2, 3, 27)


def intent_for(module: str, addr=None) -> str:
    if addr is not None and addr in SITE_INTENT:
        return SITE_INTENT[addr]
    return MODULE_INTENT.get(module, FLIP)


def describe(module: str) -> str:
    if module == "arm9":
        return "ARM9 static (boot / low-level display setup)"
    try:
        return OVERLAY_NAMES.get(int(module[2:]), "unidentified")
    except ValueError:
        return "unidentified"
