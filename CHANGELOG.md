# Changelog

## Unreleased — `beta-ui`

Going deeper into single-screen play than rerouting alone allows: compact choices now
appear beside the question instead of taking the other screen.

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

### Field yes/no questions stay on the world

Nurse Joy's offer, and every other field script that uses the shared green two-button
controller, now keeps the overworld on the top screen. `Oui / Non` or `Yes / No` appears
in the right-hand end of the existing dialogue window and follows the game's live
selection; the game still owns Up, Down, A, B and the result passed back to the script.

This controller also owns longer lists. Only its binary states are drawn: setup and
teardown keep the world visible, while PC options, shops and multichoice states still
raise their full lower-screen UI. Every pointer in the controller chain is range-checked
and verified through two `FieldSystem` back-references; an unexpected layout falls back
to the old screen swap instead of drawing or dereferencing arbitrary memory.

The field prompt aliases the existing language-neutral battle yes/no tiles, so it adds a
new layout without storing another copy of the images.

### Post-evolution move questions stay beside the Pokémon

The two-button screen shown after an evolution asks first whether to forget a move and,
when necessary, whether to stop trying to teach it. Both questions now keep the evolution
scene on top and draw the same localized `Oui / Non` or `Yes / No` labels in the existing
dialogue window.

This is not the field controller: it is an ARM9 state machine owned by the evolution task.
The patch validates the active VBlank callback, its task-data argument, the `BgConfig`, the
live `Window` and its exact 27×4 geometry before drawing. Setup defaults to Yes; active and
confirmation frames mirror the native 1/2 selection. Any unexpected pointer, geometry,
state or selection fails closed without writing VRAM.

Up, Down, A and B remain entirely native, including B selecting and confirming No. The
new layout aliases the battle yes/no geometry and image data, so no translated strings or
tiles are duplicated.

### Oak's speech answers on his own screen

The questions at the start of a new game no longer take the screen. **GARÇON / FILLE**
appears beside Oak's text for the gender question, **OUI / NON** for the gender and name
confirmations, and the highlight follows the game's own cursor.

Laid out the way each question is actually read: the gender options side by side, because
`OakSpeech_GenderSelectHandleInput` moves on left and right, and the confirmations stacked,
because they go through the generic multichoice handler on up and down.

The words come from the ROM like the battle ones — `msg_0286` for boy and girl, `msg_0219`
for Oak's own yes and no — so this stays language-neutral.

The selected band is no longer neutral grey. While a question is active, palette index 12
of Oak's dialogue borrows the intro's own edition colour: blue/silver in SoulSilver and
gold in HeartGold. Normal text retains Oak's original ink, shadow and paper indices.

The brief lower-screen indicator flash before each custom prompt is also fixed. Oak's
messages contain a `{YESNO 0}` text control, and the asynchronous text printer used to
render it after the hook's VRAM wipe. The hook now suppresses that exact control in Oak's
validated live message string before it reaches the printer; tutorial text and other text
controls are untouched.

Only two swaps remain in the intro: the naming keyboard, which genuinely needs the touch
screen, and the tutorial menu, whose three options of running text will not fit beside the
question. The gender flow used to swap for its whole state range, which flipped the screen
back and forth through the fades between prompts; that is gone.

### The overworld menu is drawn on the world

**X** no longer takes the screen away. The menu appears as a panel in the top-right corner
of the world — two columns of four, the same grid the touch menu uses — and the highlight
follows the D-pad, including left and right jumping between the columns. Sub-menus are
unchanged: pick `SAC` and the bag opens on the top screen exactly as before.

The grid is fixed and entries you have not earned leave their slot **empty**, which is what
the touch menu does — early on, `SAC` sits alone in the left column with `DRESSEUR`,
`SAUVER` and `OPTIONS` down the right. Availability comes from `inhibitIconFlags`, the
game's own answer, so the panel matches the touch screen entry for entry.

The Safari Zone, the Bug Contest and Pal Park use a different arrangement that cannot be
reproduced from outside the touch overlay; those are detected and still swap the screen,
rather than being drawn wrong.

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

### The shop menu is drawn on the world

`ACHETER / VENDRE / QUITTER` appears in the top-right corner and the screen stays on the
world; picking one opens it on the top screen as before.

The machinery behind it is general — the shop's menu and all three of the PC's are the
same object underneath — but a menu is only drawn if the patch **recognises** it, by its
entry count and the characters of its first entry. Anything else swaps, as it always did,
so an NPC choice the patch has never seen can never come up with the wrong words on it.

Only the shop is wired up so far. The rest is a storage limit rather than an unknown: the
four label sets need 15 KB and there are about 3.6 KB left. See `docs/FINDINGS.md`.

### Behaviour fixed along the way

- The bag and party open on the top screen the first time, not the second — they run as
  overlay 8 and leave the menu id on the root menu, so the overlay id is checked first.
- The highlight no longer flashes back to `ATTAQUE` when you confirm, or after a trip
  into the bag: it is frozen at the moment you press A.
- Mashing A through the battle intro no longer pins the menu, because the game's menu id
  says no menu is open yet.
- Oak's obsolete lower-screen focus indicator no longer flashes immediately before the
  custom gender and confirmation choices.
- **L + R** in battle holds until the menu you are on changes, rather than being undone
  on the next frame.

### Notes

- Region-neutral like the rest: every address is derived from the ROM, and the struct
  offsets are code-derived so they do not move between regions. Verified against IPGF,
  IPKF and IPKE.
- Payload grows from 1452 to 26248 bytes of the ~31 KB of free ITCM.
- The X menu's panel sizes itself: the cell width comes from the widest translated label,
  so the French build is 18 tiles across and the English one 16, and the patcher refuses
  rather than clipping a language whose words do not fit.
- The earlier field yes/no attempt followed `ListMenu2D` and was abandoned. Tracing
  `GetMenuChoice` into overlay 27 exposed the real custom controller; the failed paths and
  the resolution are both preserved in `docs/FINDINGS.md`.

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
