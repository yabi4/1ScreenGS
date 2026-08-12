# Changelog

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
