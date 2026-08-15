# Changelog

## Unreleased — `beta-ui`

Going deeper into single-screen play than rerouting alone allows: the two places that
asked you a question on the other screen now ask it on the one you are looking at.

### The battle command menu is drawn on the battle scene

`ATTAQUE / SAC / FUITE / POKéMON` now sit in the right-hand end of the battle message
window, which is otherwise empty. The scene never leaves the top screen while you choose,
the highlight follows the D-pad, and the screen only changes once you have picked
something the game draws on the touch screen — the move list, the bag, the party.

Binary prompts ("… changer de Pokémon?") get a small `Oui / Non` box in the same window
instead of taking the screen.

**The ~1 s timeout is gone**, along with the D-pad/A trigger that raised the menu and the
guessing about intent that came with it. Nothing is timed any more.

### The labels are the game's own words

Pulled out of the ROM being patched and rasterised at patch time
(`onescreen/labels.py`) — `msg_0197` for the strings, the game's own font for the glyphs.
A French build says ATTAQUE / SAC / POKéMON / FUITE, an English one FIGHT / BAG / POKéMON
/ RUN, from the same code. At runtime the hook only copies finished tiles into VRAM the
game has already allocated: no font, no heap, no call into game code.

### Oak's speech answers on his own screen

The questions at the start of a new game no longer take the screen. **GARÇON / FILLE**
appears beside Oak's text for the gender question, **OUI / NON** for the gender and name
confirmations, and the highlight follows the game's own cursor.

Laid out the way each question is actually read: the gender options side by side, because
`OakSpeech_GenderSelectHandleInput` moves on left and right, and the confirmations stacked,
because they go through the generic multichoice handler on up and down.

The words come from the ROM like the battle ones — `msg_0286` for boy and girl, `msg_0219`
for Oak's own yes and no — so this stays language-neutral.

Only two swaps remain in the intro: the naming keyboard, which genuinely needs the touch
screen, and the tutorial menu, whose three options of running text will not fit beside the
question. The gender flow used to swap for its whole state range, which flipped the screen
back and forth through the fades between prompts; that is gone.

### The overworld menu is drawn on the world

**X** no longer takes the screen away. The menu appears as a panel in the top-right corner
of the world — two columns of four, the same grid the touch menu uses — and the highlight
follows the D-pad, including left and right jumping between the columns. Sub-menus are
unchanged: pick `SAC` and the bag opens on the top screen exactly as before.

The entries come from the game's own list rather than a fixed one. The hook reads
`selectionToAction[]` out of `StartMenuTaskData` and maps each cell through it, so Safari,
the Bug Contest, Pal Park and a save that has not earned the Pokédex yet all draw the right
words in the right order without the patcher knowing which case it is in.

`DRESSEUR` stands in for the trainer-card row, which on the touch screen shows your name:
the game expands that at runtime from a placeholder, and patch-time rasterisation cannot
know it. The word is still the ROM's own — `msg_0282` entry 5, `TRAINER` in English.

This is the first thing the patch draws with **no window to borrow**. Battles and Oak's
speech both wrote into a message window the game had already created; the overworld has
none, so this writes a tilemap as well as pixels. It needs no display registers touched at
all, because `MAIN_3` is already priority 0 and the 3D world is BG0 at priority 1.

Highlighting costs no pixels either — the selected cell's tilemap entries are written with
a different palette number, the same trick `ov27_0225B398` uses on the touch screen. One
finished image per highlighted entry would have been 32 KB against 11 KB of free ITCM.

### Behaviour fixed along the way

- The bag and party open on the top screen the first time, not the second — they run as
  overlay 8 and leave the menu id on the root menu, so the overlay id is checked first.
- The highlight no longer flashes back to `ATTAQUE` when you confirm, or after a trip
  into the bag: it is frozen at the moment you press A.
- Mashing A through the battle intro no longer pins the menu, because the game's menu id
  says no menu is open yet.
- **L + R** in battle holds until the menu you are on changes, rather than being undone
  on the next frame.

### Notes

- Region-neutral like the rest: every address is derived from the ROM, and the struct
  offsets are code-derived so they do not move between regions. Verified against IPGF,
  IPKF and IPKE.
- Payload grows from 1452 to 25300 bytes of the ~31 KB of free ITCM.
- The X menu's panel sizes itself: the cell width comes from the widest translated label,
  so the French build is 18 tiles across and the English one 16, and the patcher refuses
  rather than clipping a language whose words do not fit.
- A field yes/no for the overworld's prompts was attempted and abandoned — see
  `docs/FINDINGS.md` for what was disproved and why.

## v0.1b — first public release

Playable start to finish on French SoulSilver and HeartGold.

### What the patch does

- **80 of 87 display-routing sites** rewritten so menus and UI land on the top screen.
  The seven left alone are deliberate: two shared ARM9 helpers, the battle system's own
  site, and the four belonging to the stylus-only screens.
- A **resident hook in unused ITCM** (~1.4 KB of the 31 KB free) for everything that has
  to change while you play.

### Behaviour

- **Battles** — the scene keeps the screen so you can read what happened; the command menu
  comes up on the D-pad or A, steps aside after ~1 s, stays put once you have selected
  something, and hands the screen back the instant you confirm a move. Item lists, the
  party list and the bag sub-screens follow.
- **Overworld menu** — X brings it up, B or X puts the world back. Presses the game
  ignores (on a ladder, mid-cutscene) no longer swap the screen.
- **Field script menus** — shop lists, NPC choices and the PC option list.
- **Pokédex** — the species grid, and the area map on a Pokémon's detail level.
- **PC box** — the option list and the box itself, for both Pokémon and items.
- **Flying, Dig, Escape Rope** — the animation is on screen from the moment you confirm.
- **Evolution** and any move it teaches.
- **New game** — Oak's speech, the tutorial menu and the gender picker.
- **Name entry** — the keyboard.
- **L + R** swaps manually anywhere, as an escape hatch.

### Compatibility

Region support is derived from the ROM rather than tabulated: the patcher finds code by
instruction shape, reads the addresses it needs out of the ROM's own literals, measures the
region shift twice from independent places, and refuses to build if they disagree. Every
hardcoded ARM9 address is checked against a byte signature and dropped if the code does not
match.

| game code | game | status |
|---|---|---|
| `IPGF` | SoulSilver (France) | play-tested |
| `IPKF` | HeartGold (France) | play-tested |
| `IPKE` | HeartGold (USA) | resolves correctly; battles not play-tested |

### Known limitations

- The trainer-card signature, the Ruins of Alph puzzles and the Pokéathlon stay on the
  touch screen. They genuinely need the stylus and cannot be fixed by rerouting.
- 19 applications inherit their routing rather than setting it; three were wrong and are
  handled, the rest are untested. See `docs/AUDIT.md`.
- US battles have not been played.
