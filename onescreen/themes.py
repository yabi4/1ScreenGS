"""Colour themes for everything this patch draws.

Two things get coloured, and they are not coloured the same way.

**The panels** - the X menu, the shop's and the PC's menus - carry their own
palettes in the label blob, so a theme is nothing more than a different set of
sixteen halfwords. Nothing else has to change: the blob already reserves the
space, and the hook copies whatever is there.

**The selected band** behind a highlighted choice is palette index 12 of a
palette the GAME owns, not us. Stock, the patch simply borrows whatever sits
there - the salmon in the battle message palette. Theming it means writing that
entry, which the hook does per frame while a prompt is drawn.

Colours are BGR555, five bits a channel, which is what DS palette RAM takes.
"""


def bgr555(r: int, g: int, b: int) -> int:
    """Five bits a channel, as DS palette RAM stores them."""
    return (b << 10) | (g << 5) | r


def from_hex(rgb: str) -> int:
    """#rrggbb to BGR555, rounding to nearest rather than truncating.

    Truncation costs up to a whole step out of 31 and consistently darkens; the
    themes below are quoted as the hex the user chose, so they should land as
    close to it as five bits allow.
    """
    rgb = rgb.lstrip("#")
    if len(rgb) != 6:
        raise ValueError(f"expected #rrggbb, got {rgb!r}")
    r, g, b = (int(rgb[i:i + 2], 16) for i in (0, 2, 4))
    return bgr555(*((c * 31 + 127) // 255 for c in (r, g, b)))


# Palette indices, matching what the font rasteriser emits. Kept here as well as
# in labels.py so a theme can be read on its own.
FG, SHADOW, BORDER, BORDER_DK, PAPER = 1, 2, 3, 4, 15

WHITE = bgr555(31, 31, 31)
INK_BLACK = bgr555(1, 1, 2)

# The panel body is white, faintly tinted towards the theme so it reads as part
# of that game without becoming a colour in its own right. One step in five bits
# is about 8/255, so these are as gentle as the hardware allows.
PAPER_PLAIN = WHITE
PAPER_GOLD = bgr555(31, 30, 28)
PAPER_SILVER = bgr555(28, 30, 31)


def _panel(paper, ink, border, border_dk, hi_paper, hi_ink):
    """The two palettes a panel needs, as (normal, highlighted).

    The frame colours are deliberately identical in both. The frame's tilemap
    entries always name the NORMAL palette - baked into the X menu's frame map
    and written at runtime for the list menus - so a frame that differed between
    the two states could not be expressed without changing both of those.

    SHADOW is set to the paper colour rather than to a darker one: the font puts
    a drop shadow under every glyph, which suits pale text on a dark box and
    muddies dark text on a pale one.
    """
    frame = {BORDER: border, BORDER_DK: border_dk}
    return (
        {0: 0, FG: ink, SHADOW: paper, PAPER: paper, **frame},
        {0: 0, FG: hi_ink, SHADOW: hi_paper, PAPER: hi_paper, **frame},
    )


# Each theme: the panel's two palettes, and the colour of a selected band.
#
# `band` is what a highlighted choice is drawn on in the battle menus, the field
# and evolution prompts, and Oak's questions. All three are light, because the
# text drawn over them is the game's own dark ink.
THEMES = {
    "classic": {
        "label": "Classic",
        "band": bgr555(23, 23, 24),
        "panel": _panel(paper=PAPER_PLAIN, ink=INK_BLACK,
                        border=bgr555(13, 13, 14), border_dk=bgr555(5, 5, 6),
                        hi_paper=bgr555(23, 23, 24), hi_ink=INK_BLACK),
    },
    "heartgold": {
        "label": "HeartGold",
        "band": from_hex("#fbd392"),
        "panel": _panel(paper=PAPER_GOLD, ink=INK_BLACK,
                        border=from_hex("#c8912f"), border_dk=bgr555(8, 5, 1),
                        hi_paper=from_hex("#fbd392"), hi_ink=INK_BLACK),
    },
    "soulsilver": {
        "label": "SoulSilver",
        "band": from_hex("#9abafb"),
        "panel": _panel(paper=PAPER_SILVER, ink=INK_BLACK,
                        border=from_hex("#5b7fc4"), border_dk=bgr555(2, 4, 8),
                        hi_paper=from_hex("#9abafb"), hi_ink=INK_BLACK),
    },
}

DEFAULT_THEME = "classic"

# What each game gets when nothing is chosen: IPK is HeartGold, IPG SoulSilver.
BY_GAME_CODE = {"IPK": "heartgold", "IPG": "soulsilver"}


def for_game_code(code):
    """The theme that suits a game code, or the default if it is not one of ours."""
    return BY_GAME_CODE.get((code or "")[:3].upper(), DEFAULT_THEME)


def get(name):
    """Return a theme by name, or raise with the list of valid ones."""
    key = (name or DEFAULT_THEME).strip().lower()
    if key not in THEMES:
        raise ValueError(
            f"unknown theme {name!r}; choose one of {', '.join(sorted(THEMES))}")
    return THEMES[key]
