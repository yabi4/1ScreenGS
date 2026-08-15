"""Rasterise the battle command labels from the ROM being patched.

The top-screen command menu draws real text - the game's own words, in the game's
own font, pulled out of the ROM at patch time. Nothing is hardcoded per language:
both the strings and the glyphs come from the dump, so a French build says
ATTAQUE / SAC / POKéMON / FUITE and an English one says FIGHT / BAG / POKéMON /
RUN without this file knowing which is which.

Everything here is offline. The hook does no text rendering at runtime - it
memcpys finished 4bpp tiles into the message window. That keeps the resident code
free of heap, font and MsgData plumbing, and lets the output be checked as a PNG
before the ROM is ever booted.

Where the data lives, and how it was confirmed
----------------------------------------------
Strings: NARC `a/0/2/7` (pret's NARC_msgdata_msg = 27), file 197 = msg_0197,
entries 924 FIGHT / 925 BAG / 926 POKEMON / 927 RUN
(src/battle/battle_input.c:1899-1912). Gen-IV message archives obfuscate both the
offset table and the text with the same two LCGs used everywhere in the series.

Font: NARC `a/0/1/6` (NARC_graphic_font = 16), file 1 - fontId 1 is what the
battle message box prints with, `AddTextPrinterParameterized(window, 1, ...)` in
BattleSystem_PrintBattleMessage (src/battle/battle_system.c:1421). ndspy's NARC
reader returns the five font files as empty, so this module parses BTAF/GMIF
itself; the archive's own file table gives 33101 bytes each.

Format (pret's struct FontHeader, src/font_data.c:15):

    u32 headerSize      16
    u32 widthDataStart  32592  == 16 + 509 * 64, which is the whole check
    u32 numGlyphs       509
    u8  fixedWidth, fixedHeight, glyphWidth, glyphHeight    16,16,2,2

so glyphs are 16x16 (GLYPHSHAPE_16x16), 64 bytes each: four 8x8 tiles of 2bpp at
+0x00 +0x10 +0x20 +0x30, placed TL, TR, BL, BR - the neighbour offsets in
DecompressGlyphTiles_FromPreloaded are +0x20 across and +0x40 down. Two bits per
pixel, most significant pair leftmost, high byte of each u16 first. One width byte
per glyph at widthDataStart. Glyph index is the character code minus one
(TryLoadGlyph, src/font_data.c:150).

Pixel values map to the message window's own palette, which is palette 11 of main
BG. Confirmed twice over: dumped live from 0x05000160 in a real battle, and stated
outright by pret's sFontInfos (src/font.c:28) as fgColor 1, bgColor 15,
shadowColor 2.
"""

import struct
import zlib

# --- palette 11 indices, per sFontInfos and the live dump --------------------
FG, SHADOW, PAPER = 1, 2, 15
HILITE = 12                     # 0x62FF, the salmon already in palette 11

# 2bpp glyph value -> palette index. 0 is "outside the glyph box" and 3 is the
# box's own background; both are paper.
VALUE_MAP = {0: PAPER, 1: FG, 2: SHADOW, 3: PAPER}

MSGDATA_NARC = "a/0/2/7"
MSGDATA_FILE = 197
FONT_NARC = "a/0/1/6"
FONT_FILE = 1                   # sFontArcParam[1][0], src/font.c:19
FONT_HEADER_SIZE = 16           # pret's struct FontHeader

# msg_0197 entries, in the order the hook indexes them. This is command order,
# matching BATTLE_INPUT_FIGHT/BAG/POKEMON/RUN.
LABEL_MSGS = (924, 925, 926, 927)

# The generic yes/no pair, from the same archive: 940 and 941. Every two-option
# battle prompt gets these rather than its own wording. The bottom screen phrases
# them per question - "Changer de Pokemon" / "Continuer le combat" - but the
# choice underneath is always binary, and a fixed Oui/Non pair reads faster on a
# scene you are already looking at than a sentence would. Decoded: Oui/Non in
# French, Yes/No in English, so this stays language-neutral like the rest.
YESNO_MSGS = (940, 941)

# The grid, in tiles, inside the battle message window. window[0] is 27 tiles
# wide starting at baseTile 31; we take the right-hand columns, which is the
# blank space the message text never reaches.
#
# 14 columns rather than the 12 first tried. The only message on screen while
# this menu is up is "What will <NAME> do?", whose longest line is the fixed part
# - 14 glyphs at 6px is 84px, under 11 tiles - and the name wraps onto the second
# line below it. 14 columns leaves 13 (104px) for that, a 20px margin, and gives
# the bottom row 22px of slack to space three words with. At 12 columns the slack
# was 6px and BAG/RUN/POKEMON ran together into one word.
GRID_COLS = 14
GRID_ROWS = 4
GRID_BASE_COL = 13
WIN_STRIDE = 27
WIN_BASE_TILE = 31

# The yes/no prompt gets its own, much smaller box. It cannot reuse the command
# grid: the blit paints its whole area, including the paper between the words, so
# a 14-tile-wide box wipes out the right-hand end of a question that is long
# enough to reach it - which is exactly what "Voulez-vous changer de Pokemon?"
# does. Three tiles is enough for Oui/Non/Yes/No (18px at the widest) and leaves
# 24 tiles, 192px, for the question.
YN_COLS = 3
YN_BASE_COL = 24

# Oak's speech asks the only questions in the game that come before you have a
# save file, and it asks them on the same tile rectangle again - dialogWindow is
# GF_BG_LYR_MAIN_0, x=2 y=19, 27x4, from sWindowTemplate_DialogMsg. Only the
# layer underneath differs, for the third time:
#
#              battle window[0]   field dialog box   Oak dialogWindow
#   layer      MAIN_1             MAIN_3             MAIN_0
#   char base  0x06004000         0x06008000         0x06018000
#   base tile  31                 0x237              0x36D
#   palette    11                 12                 6
#
# Oak's char base is GX_BG_CHARBASE_0x18000 in src/oaks_speech.c's own BgTemplate.
# Palette 6 has not been dumped, but the window is filled with 0xF
# (FillWindowPixelRect(&data->dialogWindow, 0xF, ...)), which confirms paper 15,
# and pret's sFontInfos fixes ink at 1 - so the prompt highlights by inverting
# those two rather than guessing an accent colour.
# The battle message window's own base: GF_BG_LYR_MAIN_1 with charBase 1, and
# engine A's DISPCNT character-base offset is 0 - both dumped live mid-battle.
BATTLE_CHAR_BASE = 0x06004000
OAK_CHAR_BASE = 0x06018000
OAK_BASE_TILE = 0x36D

# Oak's own yes/no, from a different archive to the battle pair: msg_0219
# entries 47 and 48. OUI/NON in French, YES/NO in English.
OAK_MSGDATA_FILE = 219
OAK_YESNO_MSGS = (47, 48)

# The gender question does have words after all - msg_0286 entries 7 and 16, whose
# row ids in the decomp are literally msg_0286_boy and msg_0286_girl. GARCON and
# FILLE in French, BOY and GIRL in English, so this stays language-neutral like
# the rest, and reads better than the charmap's bare male/female symbols.
#
# Laid out side by side rather than stacked, because that is how the game reads
# it: OakSpeech_GenderSelectHandleInput moves on PAD_KEY_LEFT and PAD_KEY_RIGHT,
# unlike the confirmations, which go through the generic multichoice handler on
# UP and DOWN. Stacking them would have implied the wrong keys.
#
# 36px + 30px plus a gap is 74px, so a 10-tile box. That leaves 17 tiles, 136px,
# for the question - "Ou bien une fille?" is about 108px.
GENDER_MSGDATA_FILE = 286
GENDER_MSGS = (7, 16)
GENDER_COLS = 10
GENDER_BASE_COL = 17
GENDER_CELL_W = GENDER_COLS * 8

CELL_H = GRID_ROWS * 8          # 32 px
ROW_H = 16                      # one glyph tall
CELL_W = GRID_COLS * 8          # 112 px
YN_CELL_W = YN_COLS * 8         # 24 px

BLOB_MAGIC = b"1SLB"

# Two sets of images, each with its own geometry, described by a 20-byte record
# in the blob header so the hook carries no dimensions of its own:
#
#   set 0, 14 tiles wide   0..3 the root command menu, one per command
#                          4    all paper, to take the menu down
#   set 1, 3 tiles wide    0,1  the two-option prompt, top and bottom
#                          2    all paper
#
# The wipe is the last image of each set rather than a special case, so taking a
# menu down is the same code path as putting one up - and each set wipes only its
# own area, which is what keeps the narrow prompt from clearing the question.
CMD_IMAGES = 5
YN_IMAGES = 3

# Byte offset from the main-engine BG character base to each tile row of a box.
# Precomputed so the resident code is a pair of copy loops with no
# multiplication: a window row is contiguous but strides by the whole 27-tile
# window width to reach the next one.
def _row_addrs(char_base, base_tile, base_col):
    """Absolute VRAM address of each tile row of a box.

    Absolute rather than an offset from one base, because the three boxes sit on
    three different character bases - the hook holds no address of its own and
    simply copies where it is told.
    """
    return tuple((char_base + (base_tile + r * WIN_STRIDE + base_col) * 32)
                 for r in range(GRID_ROWS))


OAK_IMAGES = 3                  # yes/no pair, wipe
GENDER_IMAGES = 3               # the two options, wipe
GEO_RECORD = 28                 # data_off, image_bytes, row_bytes, images, 4 row addrs
BLOB_HEADER = 128               # magic, rows, then four geometry records
CMD_ROW_BYTES = GRID_COLS * 32
CMD_IMAGE_BYTES = CMD_ROW_BYTES * GRID_ROWS
YN_ROW_BYTES = YN_COLS * 32
YN_IMAGE_BYTES = YN_ROW_BYTES * GRID_ROWS
GENDER_ROW_BYTES = GENDER_COLS * 32
GENDER_IMAGE_BYTES = GENDER_ROW_BYTES * GRID_ROWS
BLOB_SIZE = (BLOB_HEADER + CMD_IMAGES * CMD_IMAGE_BYTES
             + (YN_IMAGES + OAK_IMAGES) * YN_IMAGE_BYTES
             + GENDER_IMAGES * GENDER_IMAGE_BYTES)


class LabelError(Exception):
    """The labels could not be built from this ROM."""


# ---------------------------------------------------------------------------
# Archive reading
# ---------------------------------------------------------------------------

def _narc_files(data: bytes):
    """Return the subfiles of a NARC, by parsing BTAF and GMIF directly.

    ndspy is used everywhere else, but it hands back empty buffers for the font
    archive's first five files, which the archive's own FAT says are 33101 bytes
    each. Reading the table ourselves is a dozen lines and removes the doubt.
    """
    if data[:4] != b"NARC":
        raise LabelError("not a NARC archive")
    off = struct.unpack_from("<H", data, 12)[0]         # header size
    magic, block, count = struct.unpack_from("<4sII", data, off)
    if magic != b"BTAF":
        raise LabelError(f"expected BTAF, found {magic!r}")
    fat = [struct.unpack_from("<II", data, off + 12 + i * 8) for i in range(count)]
    off += block
    off += struct.unpack_from("<I", data, off + 4)[0]   # skip BTNF
    magic = data[off:off + 4]
    if magic != b"GMIF":
        raise LabelError(f"expected GMIF, found {magic!r}")
    base = off + 8
    return [data[base + s:base + e] for s, e in fat]


def _decode_message(archive: bytes, index: int):
    """Return one message from a Gen-IV .gmm as raw character codes."""
    count, key = struct.unpack_from("<HH", archive, 0)
    if not 0 <= index < count:
        raise LabelError(f"message {index} out of range (archive holds {count})")
    k = (key * (index + 1) * 0x2FD) & 0xFFFF
    k |= k << 16
    off, length = struct.unpack_from("<II", archive, 4 + index * 8)
    off ^= k
    length ^= k
    if off + length * 2 > len(archive):
        raise LabelError(f"message {index} runs past the end of the archive")
    k2 = (0x91BD3 * (index + 1)) & 0xFFFF
    out = []
    for j in range(length):
        out.append(struct.unpack_from("<H", archive, off + j * 2)[0] ^ k2)
        k2 = (k2 + 0x493D) & 0xFFFF
    # Messages are terminated by 0xFFFF; control codes start at 0xE000 and none
    # of the four labels contain any.
    return [c for c in out if c < 0xE000]


# ---------------------------------------------------------------------------
# Font
# ---------------------------------------------------------------------------

class Font:
    def __init__(self, blob: bytes):
        (self.header_size, self.width_start, self.num_glyphs,
         _fw, _fh, gw, gh) = struct.unpack_from("<IIIBBBB", blob, 0)
        if self.header_size != FONT_HEADER_SIZE or (gw, gh) != (2, 2):
            raise LabelError(
                f"unexpected font shape: headerSize={self.header_size} "
                f"glyph={gw}x{gh} tiles (wanted 16 and 2x2)")
        self.glyph_size = gw * gh * 16
        expect = self.header_size + self.num_glyphs * self.glyph_size
        if expect != self.width_start:
            raise LabelError(
                f"font header is inconsistent: {self.num_glyphs} glyphs of "
                f"{self.glyph_size} bytes after a {self.header_size}-byte header "
                f"ends at {expect}, but widthDataStart says {self.width_start}")
        if len(blob) < self.width_start + self.num_glyphs:
            raise LabelError("font file is shorter than its own width table")
        self.blob = blob

    def _index(self, code: int) -> int:
        if not 1 <= code <= self.num_glyphs:
            raise LabelError(f"character {code:#06x} is not in this font")
        return code - 1

    def width(self, code: int) -> int:
        return self.blob[self.width_start + self._index(code)]

    def glyph(self, code: int):
        """Return a 16x16 grid of palette indices."""
        base = self.header_size + self._index(code) * self.glyph_size
        px = [[PAPER] * 16 for _ in range(16)]
        for tile, (ox, oy) in enumerate(((0, 0), (8, 0), (0, 8), (8, 8))):
            top = base + tile * 16
            for row in range(8):
                half = struct.unpack_from("<H", self.blob, top + row * 2)[0]
                for bi, byte in enumerate(((half >> 8) & 0xFF, half & 0xFF)):
                    for p in range(4):
                        v = (byte >> (6 - 2 * p)) & 3
                        px[oy + row][ox + bi * 4 + p] = VALUE_MAP[v]
        return px


# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------

def _text_width(font: Font, codes) -> int:
    return sum(font.width(c) for c in codes)


def _layout(font: Font, labels):
    """Place the four labels and return [(x, y, codes, rect), ...].

    The arrangement follows the game's own cursor grid rather than a free choice
    (sCursorArrayMainMenu, src/battle/battle_input.c:281):

        { FIGHT, FIGHT, FIGHT }
        { BAG,   RUN,   POKEMON }

    FIGHT spans the top, the other three sit along the bottom in that order. The
    hook mirrors the game's cursor instead of driving it, so drawing any other
    arrangement would make the D-pad appear to move diagonally. It is also the
    layout of the touch menu the player already knows.
    """
    fight, bag, pokemon, run = labels
    out = []

    # Top row: FIGHT centred across the full width.
    w = _text_width(font, fight)
    out.append(((CELL_W - w) // 2, 0, fight, (0, 0, CELL_W, ROW_H)))

    # Bottom row: BAG, RUN, POKEMON left to right, gaps shared evenly.
    bottom = [bag, run, pokemon]
    widths = [_text_width(font, c) for c in bottom]
    slack = CELL_W - sum(widths)
    if slack < 0:
        raise LabelError(
            f"the bottom row needs {sum(widths)}px but only {CELL_W}px are "
            f"available; widen GRID_COLS or shorten the labels")
    gap = slack // (len(bottom) + 1)
    x = gap + (slack - gap * (len(bottom) + 1)) // 2
    for codes, w in zip(bottom, widths):
        out.append((x, ROW_H, codes, (x - gap // 2, ROW_H,
                                      w + gap, ROW_H)))
        x += w + gap
    # Reorder to command order: FIGHT, BAG, POKEMON, RUN.
    top, b_bag, b_run, b_pokemon = out
    return [top, b_bag, b_pokemon, b_run]


def _layout_yesno(font: Font, choices):
    """Place the two-option prompt: one choice above the other, both centred.

    The cursor for these menus is 1 wide and 2 tall
    (BattleCursor_CheckKeyInput(cursor, 1, 2, ...) in
    BattleInput_CursorMove_TwoOptionsMenu), so menuY alone picks the answer and
    stacking them matches how the D-pad moves.
    """
    out = []
    for i, codes in enumerate(choices):
        w = _text_width(font, codes)
        y = i * ROW_H
        out.append((((YN_CELL_W - w) // 2, y, codes, (0, y, YN_CELL_W, ROW_H))))
    return out


def _inside(rect, x, y):
    x0, y0, w, h = rect
    return x0 <= x < x0 + w and y0 <= y < y0 + h


def _layout_row(font: Font, items, cell_w):
    """Place two options side by side, centred, for a left/right choice."""
    widths = [_text_width(font, c) for c in items]
    gap = 8
    total = sum(widths) + gap * (len(items) - 1)
    if total > cell_w:
        raise LabelError(f"the row needs {total}px but only {cell_w}px are available")
    x = (cell_w - total) // 2
    out = []
    for codes, w in zip(items, widths):
        out.append((x, 0, codes, (x - gap // 2, 0, w + gap, ROW_H)))
        x += w + gap
    return out


def _render(font: Font, placed, selected, width=CELL_W, invert=False):
    """Return a `width` x CELL_H grid of palette indices.

    `invert` highlights by swapping ink and paper instead of filling with
    HILITE. The battle boxes know their palette has a usable accent at index 12
    because it was dumped from a live battle; Oak's palette 6 has not been, so
    its prompt uses only the two indices the font system guarantees everywhere.
    """
    band = FG if invert else HILITE
    sel_rect = placed[selected][3] if selected is not None else None
    canvas = [[PAPER] * width for _ in range(CELL_H)]
    if sel_rect is not None:
        x0, y0, w, h = sel_rect
        for y in range(y0, min(y0 + h, CELL_H)):
            for x in range(max(x0, 0), min(x0 + w, width)):
                canvas[y][x] = band
    for x, y, codes, _rect in placed:
        for code in codes:
            glyph = font.glyph(code)
            w = font.width(code)
            for gy in range(16):
                ty = y + gy
                if not 0 <= ty < CELL_H:
                    continue
                for gx in range(w):
                    tx = x + gx
                    if not 0 <= tx < width:
                        continue
                    v = glyph[gy][gx]
                    if v == PAPER:          # keep the highlight showing through
                        continue
                    if invert and sel_rect is not None and _inside(sel_rect, tx, ty):
                        if v != FG:
                            continue        # the shadow vanishes into the band
                        v = PAPER           # and the ink reads as paper on it
                    canvas[ty][tx] = v
            x += w
    return canvas


def _to_tiles(canvas, cols=GRID_COLS) -> bytes:
    """Pack a pixel grid into 4bpp DS tiles, row-major by tile."""
    out = bytearray()
    for trow in range(GRID_ROWS):
        for tcol in range(cols):
            for y in range(8):
                row = canvas[trow * 8 + y]
                for x in range(0, 8, 2):
                    lo = row[tcol * 8 + x] & 0xF
                    hi = row[tcol * 8 + x + 1] & 0xF
                    out.append(lo | (hi << 4))
    return bytes(out)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def build(rom, log=print) -> bytes:
    """Return the label blob for this ROM.

    `rom` is an ndspy NintendoDSRom. Raises LabelError if anything about the
    ROM's message or font data is not what this module expects, rather than
    emitting tiles that would draw as garbage on the top screen.
    """
    try:
        msg_id = rom.filenames.idOf(MSGDATA_NARC)
        font_id = rom.filenames.idOf(FONT_NARC)
    except Exception as exc:                        # noqa: BLE001
        raise LabelError(f"cannot resolve the archives: {exc}") from exc
    if msg_id is None or font_id is None:
        raise LabelError(f"{MSGDATA_NARC} or {FONT_NARC} is missing")

    archive = _narc_files(bytes(rom.files[msg_id]))
    if MSGDATA_FILE >= len(archive):
        raise LabelError(f"{MSGDATA_NARC} has no file {MSGDATA_FILE}")
    labels = [_decode_message(archive[MSGDATA_FILE], m) for m in LABEL_MSGS]
    choices = [_decode_message(archive[MSGDATA_FILE], m) for m in YESNO_MSGS]
    if OAK_MSGDATA_FILE >= len(archive):
        raise LabelError(f"{MSGDATA_NARC} has no file {OAK_MSGDATA_FILE}")
    oak = [_decode_message(archive[OAK_MSGDATA_FILE], m) for m in OAK_YESNO_MSGS]
    if GENDER_MSGDATA_FILE >= len(archive):
        raise LabelError(f"{MSGDATA_NARC} has no file {GENDER_MSGDATA_FILE}")
    gender = [_decode_message(archive[GENDER_MSGDATA_FILE], m) for m in GENDER_MSGS]
    for msg, codes in zip(LABEL_MSGS + YESNO_MSGS + OAK_YESNO_MSGS + GENDER_MSGS,
                          labels + choices + oak + gender):
        if not codes:
            raise LabelError(f"message {msg} decoded to nothing")

    fonts = _narc_files(bytes(rom.files[font_id]))
    if FONT_FILE >= len(fonts):
        raise LabelError(f"{FONT_NARC} has no file {FONT_FILE}")
    font = Font(fonts[FONT_FILE])

    # Each set: its layout, how many highlighted variants, pixel width, tile
    # width, and where its rows land. Kept as one table so the header, the image
    # data and the sizes cannot describe different things.
    sets = [
        (_layout(font, labels), 4, CELL_W, GRID_COLS, False,
         _row_addrs(BATTLE_CHAR_BASE, WIN_BASE_TILE, GRID_BASE_COL)),
        (_layout_yesno(font, choices), 2, YN_CELL_W, YN_COLS, False,
         _row_addrs(BATTLE_CHAR_BASE, WIN_BASE_TILE, YN_BASE_COL)),
        (_layout_yesno(font, oak), 2, YN_CELL_W, YN_COLS, True,
         _row_addrs(OAK_CHAR_BASE, OAK_BASE_TILE, YN_BASE_COL)),
        (_layout_row(font, gender, GENDER_CELL_W), 2, GENDER_CELL_W, GENDER_COLS,
         True, _row_addrs(OAK_CHAR_BASE, OAK_BASE_TILE, GENDER_BASE_COL)),
    ]

    blob = bytearray(struct.pack("<4sBBH", BLOB_MAGIC, GRID_ROWS, len(sets), 0))
    off = BLOB_HEADER
    for _placed, variants, _w, cols, _inv, addrs in sets:
        row_bytes = cols * 32
        image_bytes = row_bytes * GRID_ROWS
        blob += struct.pack("<IIHH", off, image_bytes, row_bytes, variants + 1)
        blob += struct.pack(f"<{GRID_ROWS}I", *addrs)
        off += (variants + 1) * image_bytes
    blob += b"\0" * (BLOB_HEADER - len(blob))
    if len(blob) != BLOB_HEADER:
        raise LabelError(f"header is {len(blob)} bytes, expected {BLOB_HEADER}")

    for placed_set, variants, width, cols, invert, _addrs in sets:
        for sel in range(variants):
            blob += _to_tiles(
                _render(font, placed_set, sel, width, invert), cols)
        blob += b"\xFF" * (cols * 32 * GRID_ROWS)   # the wipe: all paper
    if len(blob) != BLOB_SIZE:
        raise LabelError(f"blob is {len(blob)} bytes, expected {BLOB_SIZE}")

    fmt = lambda xs: [_text_width(font, c) for c in xs]
    log(f"  Labels   : commands {fmt(labels)} px, battle yes/no {fmt(choices)} px, "
        f"Oak yes/no {fmt(oak)} px, gender {fmt(gender)} px, {len(blob)} bytes")
    return bytes(blob)


def preview(rom, path):
    """Write a PNG of all four selection states, for eyeballing a build."""
    archive = _narc_files(bytes(rom.files[rom.filenames.idOf(MSGDATA_NARC)]))
    labels = [_decode_message(archive[MSGDATA_FILE], m) for m in LABEL_MSGS]
    choices = [_decode_message(archive[MSGDATA_FILE], m) for m in YESNO_MSGS]
    oak = [_decode_message(archive[OAK_MSGDATA_FILE], m) for m in OAK_YESNO_MSGS]
    gender = [_decode_message(archive[GENDER_MSGDATA_FILE], m) for m in GENDER_MSGS]
    font = Font(_narc_files(bytes(rom.files[rom.filenames.idOf(FONT_NARC)]))[FONT_FILE])
    placed = _layout(font, labels)
    placed_yn = _layout_yesno(font, choices)
    placed_oak = _layout_yesno(font, oak)
    placed_gender = _layout_row(font, gender, GENDER_CELL_W)

    colours = {FG: (56, 56, 72), SHADOW: (168, 168, 176),
               PAPER: (255, 255, 255), HILITE: (255, 190, 190)}
    gap = (200, 200, 200)
    rows = []
    plates = ([(placed, i, CELL_W) for i in range(4)]
              + [(placed_yn, i, YN_CELL_W) for i in range(2)])
    for which, sel, width in plates:
        # Narrow plates are drawn at their real size and padded, so the preview
        # shows how little of the message window the prompt actually covers.
        for line in _render(font, which, sel, width):
            px = [colours.get(v, (255, 0, 255)) for v in line]
            px += [gap] * (CELL_W - width)
            rows.append(b"\0" + bytes(b for c in px for b in c))
        rows.append(b"\0" + bytes([220, 220, 220] * CELL_W))

    def chunk(tag, data):
        body = tag + data
        return (struct.pack(">I", len(data)) + body
                + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF))

    height = len(rows)
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", CELL_W, height, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(b"".join(rows), 9))
           + chunk(b"IEND", b""))
    with open(path, "wb") as fh:
        fh.write(png)
    return path
