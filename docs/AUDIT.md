# Button-navigation audit

Touch is physically the **lower** LCD, so anything this patch moves to the top screen can
no longer be tapped. Every screen that ends up on top must therefore be fully navigable
with buttons. This document is the source-based half of that audit, done against
[pret/pokeheartgold](https://github.com/pret/pokeheartgold), plus the play-test checklist
for what source cannot answer.

It also records the most important structural discovery of the audit, which is not about
buttons at all.

## `gSystem`, and the game's own routing flag

The "state block" the hook has been reading since the beginning is pret's
`struct System gSystem` (`include/system.h`), at **`0x021D112C`** in the French ROMs. Every
address the hook derives from it is a named field, and the layout confirms each one that
was originally found by probing:

| offset | field | what the hook calls it |
|---|---|---|
| `+0x00` | `GFIntrCB vBlankIntr` | `app_callback` |
| `+0x38` | `int heldKeysRaw` | `pad_held` |
| `+0x44` | `int newKeys` | — (edges are derived in the hook instead) |
| `+0x69` | `u8 screensFlipped` | the flag name entry sets, at `0x021D1195` |

`app_callback` being `vBlankIntr` explains why it works as an app identity: **every
application installs its own VBlank callback**, so the pointer changes exactly when the
running app changes.

The important one is `screensFlipped`. The game routes its screens through a single
helper:

```c
void GfGfx_SwapDisplay(void) {                 // src/gf_gfx_planes.c
    if (gSystem.screensFlipped == 0) GX_SetDispSelect(GX_DISP_SELECT_MAIN_SUB);
    else                             GX_SetDispSelect(GX_DISP_SELECT_SUB_MAIN);
}
```

That is the shared helper at `0x02022D3E` which had to be marked `KEEP` because flipping
it inverted the overworld — now explained. And it explains the behaviour the hook works
around in two separate places: **any app that calls `GfGfx_SwapDisplay` stamps its own idea
of the routing back over ours**, which is why the battle sub-screens and the returning
field app undo a one-shot `POWCNT1` write and the hook has to re-apply it every frame.

**Setting `gSystem.screensFlipped` would be the game-native way to do all of this** and
would not need re-applying. It is not changed today because the current approach is tested
and shipping, but it is the first thing to consider in any rework — it could plausibly
replace much of the per-frame re-application logic, and possibly some of the 80 static site
flips.

## Method

Two signals, per source file:

- **touch** — `gSystem.touch*`, `System_GetTouch*`, `TouchscreenHitbox*`
- **buttons** — `gSystem.newKeys`, `heldKeys`, `newAndRepeatedKeys`, `heldKeysRaw`

A file that reads touch and never reads keys is a candidate stylus-only screen. A file that
reads both is navigable, though it does not prove *every* control has a button path.

## Result: one genuinely touch-only app

Of everything the decomp covers, exactly one application reads touch and never reads keys:

| app | overlay | verdict |
|---|---|---|
| **Ruins of Alph sliding puzzle** (`alph_puzzle.c`) | 110 | touch-only — confirmed |

Everything else that touches the touchscreen also handles buttons, including the ones that
looked riskiest:

| app | touch refs | key refs |
|---|---|---|
| Pokégear (map / phone / radio / configure) | 187 | 109 |
| battle input | 77 | 65 |
| Voltorb Flip | 20 | 22 |
| main menu | 9 | 50 |
| party menu + context menu | 8 | 44 |
| options | 5 | 17 |
| naming screen | 4 | 18 |
| berry pots | 13 | 39 |

The remaining touch-heavy files are framework, not screens: `touchscreen.c`,
`touch_hitbox_controller.c`, `touchscreen_list_menu.c`.

This is consistent with what shipped: the three screens the patch deliberately leaves on
the bottom are the trainer-card signature, the Alph puzzles and the Pokéathlon — all
genuinely stylus-driven, and none of them fixable, because moving them to the top would
make them visible but untappable.

## What this method cannot clear

**75 of 119 overlays are still raw assembly in the decomp** (34 fully decompiled, 10
partly). The gap includes several of the most-used screens:

| overlay | app | decomp coverage |
|---|---|---|
| 5 | party menu | **asm only** |
| 14 | PC box storage | **asm only** |
| 15 | bag | **asm only** |
| 52 | trainer card signature | not in `main.lsf` as src |
| 12 | battle | partial |
| 18 | Pokédex | partial |
| 96 | Pokéathlon | partial |

So the source audit above is a *lower bound*: it proves the Alph puzzle is stylus-only and
clears the apps it covers, but it cannot vouch for the bag, the party menu or the PC box.
**Those have since been play-tested and all pass** — see the checklist below.

## The five ways this breaks

Every bug found in play so far falls into one of five classes. Knowing the classes is
worth more than any list of screens, because it tells you what to *look* for.

**1. A screen built during a fade, swapped after it.** Symptom: the right content arrives,
but you watch it appear on the wrong screen first. Cause: acting on the state where the
screen is *finished* rather than where it is *built*. The Pokédex area map took two
attempts for this reason — and the second failed because a state handler tail-called
another, so the state we keyed on was never written. **Swap during the game's own fade,
while both engines are black.**

**2. A latch outliving the thing it latched.** Symptom: the wrong screen sticks for a long
time, and something unrelated (walking, pressing B) fixes it. Cause: we raised a flag on an
event and nothing lowered it. Flying, Dig and Escape Rope all reach the world *through* the
menu, so the menu latch survived into gameplay.

**3. Assuming which engine an app draws on.** Symptom: the top screen shows the wrong half,
or goes blank. The touch UI is on engine B for most apps — but **not the PC box**, which
draws its grid on engine A. Two shipped attempts pushed it the wrong way before anyone
disassembled the app's own `POWCNT1` site, which answers it in one look.

**4. The app having the last word.** Symptom: our swap appears to do nothing at all. Cause:
the app re-routes after we do, sometimes from a VBlank callback, so *where in the frame* we
write decides who wins. `gSystem.screensFlipped` is the game-native lever when this happens.

**5. A sub-level inside an app.** Symptom: the app is on top, but one screen inside it is
not — battle item lists, the party list, the Pokédex map. Each needs its own rule.

## Where to look next

45 overlays are applications with an `OverlayManagerTemplate`. **26 set `POWCNT1`
themselves**, so the static flip already covers them. The other **19 set nothing and simply
inherit whatever routing is current** — historically exactly how the party screen ended up
stranded on the bottom. That makes them the risk list:

| overlay | what it is |
|---|---|
| 16 | berry pots |
| 43 | Pal Pad |
| 53 | Oak's speech (intro) |
| 58 | apricorn box |
| 61 | choose starter |
| 69 | Geonet globe |
| 96 | Pokéathlon course |
| 45, 50, 55, 76, 78, 91, 92, 93, 95, 104, 105, 121 | unnamed in the decomp |

An inheriting app is not necessarily wrong — it is right whenever the routing it inherits
happens to suit it. But it is the population where a wrong screen is most likely, and it
has the worst record so far: **Oak's speech (53) was the first one played and it was
wrong**, as were the fly map and the evolution scene. All three are now handled
explicitly. The rest remain untested.

### Play-test checklist

For each screen: reach it, then try to do everything with the D-pad, A, B, L, R and
Start/Select only. Note anything that responds only to a tap.

**Cleared in play** — the ones source could not vouch for, now confirmed by hand:

- [x] **Bag** — every pocket, using an item, giving an item, sorting, TM/HM list
- [x] **Party menu** — switching order, summary pages, using an item on a Pokémon
- [x] **PC box** — the option list, moving Pokémon, item storage
- [x] **Pokégear** — map, radio tuning, phone call list, configuration
- [x] **Shops** — buy and sell, quantity selection

That closes the three biggest gaps this method left open. The bag, the party menu and the
PC box are all raw assembly in the decomp, so nothing but play could have cleared them —
and the Pokégear was the largest touch surface in the whole audit at 187 references.

**Still open:**

- [ ] Move relearner / move deletion
- [ ] Mail writing (Easy Chat)
- [ ] Voltorb Flip
- [ ] Apricorn box, berry pots
- [ ] Trainer card pages (the signature page is expected to fail)

Anything that fails is fixable the same way the Pokédex was, provided it is an
OverlayManager application — 45 of 129 overlays expose exactly one template that can be
found structurally.
