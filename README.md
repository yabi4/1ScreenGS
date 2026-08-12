# 1ScreenHGSS

Play **Pokémon HeartGold / SoulSilver** on a single screen.

> **v0.1b** — playable start to finish on French SoulSilver and HeartGold. See
> [Compatibility](#compatibility) and [Status](#status).

The DS puts half of HGSS on the touch screen — the bag, the party, the Pokédex, and
critically the battle command menu. That makes the game awkward on a handheld like the
Steam Deck, where you want one screen filling the panel. This patch reroutes the game so
that whatever you actually need is on the **top** screen, automatically.

No new UI is drawn and no assets are replaced. The DS has two independent 2D engines, and
`POWCNT1` bit 15 decides which one drives the upper LCD; the patch rewrites the ~87 places
the game sets that, and adds a small resident hook for the cases that need to change while
you play.

|  | on the top screen |
|---|---|
| Overworld | the world (unchanged) |
| Bag, party, Pokégear, main menu, trainer card, options | their UI |
| Pokédex | the species grid, and the **area map** on a Pokémon's detail level |
| PC box | the option list and the box — moving Pokémon, item storage |
| Field menus | shop lists, NPC choices — anything a script draws below |
| Overworld menu (**X**) | comes up with the menu, **B** puts the world back |
| Name entry | the keyboard |
| New game | Oak's speech, the tutorial menu and the gender picker |
| Flying, Dig, Escape Rope | the animation, from the moment you confirm |
| Evolution | the Pokémon, and any move it learns afterwards |
| **Battles** | the scene — until you reach for the menu, then the menu |

Battles are the interesting part. The battle scene keeps the top screen so you can read
what just happened; the command menu comes up when you press the **D-pad or A**, steps
aside after ~1 s if you stop, stays put once you've selected something, and hands the
screen back the instant you confirm a move. Move names, types and PP are all readable up
there, and everything is D-pad navigable.

**L + R** swaps the screens manually at any time, as an escape hatch.

## Requirements

- Your own dump of Pokémon HeartGold or SoulSilver (**French versions are the tested
  ones** — see [Compatibility](#compatibility))
- [Python 3.9+](https://www.python.org/) and [ndspy](https://github.com/RoadrunnerWMC/ndspy):
  `pip install ndspy`

## Use

```bash
python patch.py "Pokemon - Version Argent SoulSilver.nds"
```

That writes `Pokemon - Version Argent SoulSilver-1screen.nds` next to it. Your original
file is never modified.

Then in your emulator show only the top screen — in melonDS,
`Config → Screen sizing → Top only`. Full setup notes and the complete control list are in
**[docs/USAGE.md](docs/USAGE.md)**.

Save files are ordinary battery saves and work on the unpatched ROM too, so you can move
between the two freely.

## Compatibility

| game code | game | status |
|---|---|---|
| `IPGF` | SoulSilver (France) | **play-tested** — the reference build |
| `IPKF` | HeartGold (France) | **play-tested**, including a fresh start through Oak's speech |
| `IPKE` | HeartGold (USA) | patches and resolves every address correctly; **battles not play-tested** |
| other `IPGx` / `IPKx` | HGSS, other languages | untested — good chance of working |

Nothing is hardcoded per region. The patcher finds the code it edits by *instruction
shape*, and every address the resident hook needs is resolved from the ROM being patched:
the game-state block is read out of the main loop's own literal, the overlay values come
from the overlay table, the Pokédex entry point is found structurally, and the battle
phase word is read from the overlay loader's own literal. Measured across French and US,
ARM9 **code** addresses are identical and only data shifts (US = FR − 0x20); the patcher
measures that shift twice from independent places and refuses if they disagree, rather
than emitting a subtly broken ROM.

If you try another language, please open an issue either way.

Diamond/Pearl/Platinum are **not** supported — different code, different overlays.

## Status

Everything below is behaviour that has been played through, not just implemented:
the overworld and its menus, battles including sub-screens and the command-menu timing,
the bag through every pocket, the party menu including reordering and summaries, the
Pokédex with its area map, the PC boxes for Pokémon and items, the Pokégear's map, radio,
phone and configuration, shops and NPC choice menus, flying, Dig and Escape Rope,
evolution and the moves it teaches, and a new game from the title screen through Oak's
speech to walking outdoors.

Notably that covers the bag, the party menu and the PC box, which are still raw assembly
in the decompilation — nothing but play could have cleared them — and the Pokégear, which
was the largest touch surface found anywhere in the audit.

Known gaps, in order of how likely you are to meet them:

- **19 applications set no display routing of their own** and inherit whatever is current.
  Three of them turned out to be wrong and are now handled; the rest are listed in
  [docs/AUDIT.md](docs/AUDIT.md) and are untested. Berry pots, the apricorn box and the
  Pal Pad are the ones a normal playthrough will reach.
- **Three screens deliberately stay on the touch screen** because they genuinely need the
  stylus — the trainer-card signature, the Ruins of Alph puzzles and the Pokéathlon. These
  are not fixable: moving them up would make them visible but untappable.
- **US battles have never been played.** Every address the hook needs is derived from the
  ROM and cross-checked, so it should be fine, but nobody has confirmed it.

If you find a screen on the wrong side, a savestate makes it quick to diagnose —
see [docs/USAGE.md](docs/USAGE.md#troubleshooting).

## Button navigation

Touch is physically the *lower* LCD, so anything shown on top cannot be tapped — every
screen the patch moves up has to be fully navigable with buttons.

A source-level audit against the decomp found the Ruins of Alph puzzle to be the only
genuinely touch-only app it covers, and cleared everything else it covers. The bag, party
menu and PC box are raw assembly there and could only be cleared by playing them, which
has now been done. See **[docs/AUDIT.md](docs/AUDIT.md)** for the method, the results and
what is still unchecked.

## Development

The whole toolchain is here: ROM unpacking, the display-site scanner, savestate diffing,
build and emulator-driving helpers. See **[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)** to
get set up, **[docs/AUDIT.md](docs/AUDIT.md)** for the button-navigation audit and what
the decomp says about the game's own screen routing, and
**[docs/FINDINGS.md](docs/FINDINGS.md)** for the reverse-engineering
write-up — memory addresses, what each discovery was, and the dead ends, so none of it
needs rediscovering.

## Legal

This repository contains **no game data** — no ROMs, no save files, no extracted assets.
It is a patcher that operates on a dump you provide of a game you own. Pokémon is a
trademark of Nintendo / Creatures / GAME FREAK, who are not affiliated with this project.

Tooling is MIT licensed — see [LICENSE](LICENSE).

## Credits

Overlay identities come from [pret/pokeheartgold](https://github.com/pret/pokeheartgold),
whose overlay numbering matches the retail ROM. ROM handling uses
[ndspy](https://github.com/RoadrunnerWMC/ndspy). Built and tested against
[melonDS](https://melonds.kuribo64.net/).
