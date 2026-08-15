# Using 1ScreenHGSS

## Patching your ROM

You need [Python 3.9+](https://www.python.org/) and ndspy:

```bash
pip install ndspy
```

Then, from the repository folder:

```bash
python patch.py "Pokemon - Version Argent SoulSilver.nds"
```

This writes `…-1screen.nds` alongside your file. The original is never modified.

Useful flags:

```bash
python patch.py mygame.nds -o soulsilver-1screen.nds   # choose the output name
python patch.py mygame.nds --identify                  # just report what the ROM is
python patch.py mygame.nds --no-hook                   # static flips only, no toggle
```

`--no-hook` skips the resident code entirely: you get the screen flips for menus but no
automatic battle swapping, no X-menu handling and no L+R toggle. Only useful for
debugging.


### Save files

Save files are ordinary battery saves and are **not** touched by the patch. Name your
`.sav` to match the patched ROM (`soulsilver-1screen.sav`), and it will work on the
unpatched ROM too — you can switch back and forth whenever you like.

## Controls

| button | what it does |
|---|---|
| **X** | opens the overworld menu **and brings it to the top screen**; press again to close |
| **B** | closes it; the world goes back on top |
| **L + R** | swaps the screens manually, any time — except inside the PC box, which holds its own routing every frame; press B to leave first |

Everything else plays normally. You should rarely need L+R: the patch follows the game
rather than your button presses, so pressing X somewhere the menu cannot open (on a
ladder, mid-cutscene) does nothing, and using Dig or an Escape Rope from the menu hands
the screen back to the world by itself.

## What ends up on the top screen

**Automatically, all the time:**

| screen | on top |
|---|---|
| Overworld | the world (unchanged — as it should be) |
| Bag | pocket tabs and item grid |
| Party | the Pokémon list |
| Pokédex — species grid | the grid |
| Pokédex — a Pokémon's detail level | **the area map** |
| PC box | the option list **and** the box itself — Pokémon and item storage |
| Field menus | shop lists, NPC choices, anything a script puts on the touch screen |
| Pokégear, main menu, trainer card, options | their UI |
| Name entry | the keyboard |
| New game — Oak's speech | his text, with his questions answered beside it (below) |
| Flying | the flight animation, from the moment you confirm the destination |
| Dig, Escape Rope, Teleport | the world, not the menu you set off from |
| Evolution, and any move it teaches | the Pokémon and the narration |

**In battle**, the scene stays up while you choose. The commands are drawn onto it:

| what is happening | on top |
|---|---|
| a turn is resolving | the battle scene |
| `Que doit faire …?` appears | the scene, with `ATTAQUE / SAC / FUITE / POKéMON` on it |
| you move the **D-pad** | the scene; the highlight moves with you |
| a yes/no question is asked | the scene, with a small `Oui / Non` box |
| you pick `ATTAQUE` | the move list |
| you pick `SAC` or `POKéMON` | the bag or the party |
| you confirm a move | the scene, immediately |

The commands sit in the right-hand end of the message window, which is otherwise empty —
`ATTAQUE` across the top, then `SAC`, `FUITE` and `POKéMON` along the bottom. That is the
arrangement the game's own cursor moves through, so the highlight tracks the D-pad
exactly; it starts on `ATTAQUE` because the game's cursor does.

There is no timing anywhere in this. Nothing steps aside after a delay, and no press
moves the screen out from under you — the screen changes when, and only when, you have
picked something the game draws on the touch screen.

**Starting a new game**, Oak's questions are answered on his own screen:

| what is happening | on top |
|---|---|
| Oak talking | Oak, as always |
| the tutorial menu (three options) | the menu — this one still swaps |
| `Es-tu un garçon?` | Oak, with `GARÇON` and `FILLE` beside the text, left/right |
| confirming your gender | Oak, with `OUI / NON` stacked, up/down |
| entering your name | the keyboard — the one deliberate swap |
| confirming your name | Oak, with `OUI / NON` |

The gender options sit side by side and the confirmations stack, because that is how the
game reads them: the gender question moves on left and right, the confirmations on up and
down. The highlight follows whichever the game's own cursor is on.

One cosmetic wart: the small "look at the bottom screen" indicator can flicker for a frame
or two just before a prompt appears. It is drawn by something that runs after this patch
does; see `docs/FINDINGS.md` for what was ruled out.

**L + R** still works during a battle. It holds until the menu you are on changes, so
backing out of the move list hands control back to the patch.

## Emulator setup (melonDS)

- `Config → Screen sizing → **Top only**`
- Turn integer scaling **off** so the single screen fills the panel
- Map **L** and **R** somewhere reachable — you should rarely need them, but they are the
  manual override
- Optionally bind melonDS's own `HK_SwapScreens` to a spare button as a second escape
  hatch; it works independently of the in-ROM toggle

On a Steam Deck, EmuDeck's melonDS works well with the same settings.

## Known limitations

- **Touch is physically the lower LCD.** Anything shown on the top screen cannot be
  tapped, so everything must be done with buttons. That is fine for battles, bag, party
  and menus, which are all button-navigable.
- **Three screens deliberately stay on the bottom** because they genuinely need the
  stylus: the trainer-card signature, the Ruins of Alph sliding puzzles, and the
  Pokéathlon. Press L+R to reach them.
- A **source-level** audit against the decompilation found the Alph puzzle to be the only
  genuinely touch-only screen it covers, and cleared everything else it covers as
  button-navigable. But 75 of 119 code overlays are still raw assembly there, including
  the bag, the party menu and the PC box, so that audit is a lower bound rather than a
  clearance — see [AUDIT.md](AUDIT.md).
- **19 applications set no display routing of their own** and simply inherit whatever is
  current. Most are fine; three of them (Oak's speech, the evolution scene, the fly map)
  turned out not to be and are now handled explicitly. The rest are listed in
  [AUDIT.md](AUDIT.md) and are the likeliest place for a remaining wrong screen.
- If a screen is on the wrong side, **L+R always works** as an escape hatch.

## Troubleshooting

**The patcher says my ROM is unrecognised.** Only the French dumps have been tested. The
patch still applies — it locates code by instruction shape, not fixed offsets — but please
report whether it worked.

**A screen is on the wrong side.** Press L+R, then please open an issue. Two things make
it far quicker to fix, and both are cheap:

1. a **screenshot** of both screens at the bad moment;
2. a **melonDS savestate** taken there.

With a savestate the cause is usually identifiable without guessing:

```bash
python tools/savestate.py hook mystate.mln
```

That prints the patch's own variables — which latch is set, what the game's task manager
is running — and it is how most of the awkward bugs in this project were actually found.
Reasoning without it produced several confident wrong answers.

**The game does not boot.** Check you patched a clean, un-trimmed dump — run
`python patch.py yourrom.nds --identify` and compare the SHA-1 with the README table.
