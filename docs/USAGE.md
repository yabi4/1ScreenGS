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
| New game — Oak's speech | his text, and the **tutorial menu** and **gender picker** when those come up |
| Flying | the flight animation, from the moment you confirm the destination |
| Dig, Escape Rope, Teleport | the world, not the menu you set off from |
| Evolution, and any move it teaches | the Pokémon and the narration |

**In battle**, the screen follows what you are doing:

| what is happening | on top |
|---|---|
| a turn is resolving | the battle scene |
| `Que doit faire …?` appears | still the scene, so you can read the result |
| you press the **D-pad** or **A** | the command menu |
| ~1 s with no input | back to the scene |
| you selected something from the menu (move list, bag, party) | the menu stays up |
| you are browsing the bag or the party | the menu stays up |
| you confirm a move | the scene, immediately |

`A` brings the menu up as well as the D-pad, because the cursor starts on `ATTAQUE` — if
it did not, pressing A straight away would open the move list where you cannot see it.

The first `A` only brings the menu up; it does not hold it there. Holding it takes a
selection made from a menu you can actually see. That is what stops the menu getting
stuck on screen when you mash A through the battle intro.

Pressing **B** to back out of a submenu re-arms the ~1 s timeout, so the menu steps
aside again once you stop.

The delay is `IDLE_FRAMES` in `src/hook.s` (frames at 60 fps) if you want it different.

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
