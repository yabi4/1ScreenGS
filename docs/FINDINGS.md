# 1ScreenHGSS — reverse-engineering findings

Target ROMs (user's own dumps, in `roms/`):

| file | gamecode | sha1 |
|---|---|---|
| `ipgf.nds` | `IPGF` — SoulSilver, France, rev 0 | `6ED98D446EB65861C71FC5F94BDC35691667F665` |
| `ipkf.nds` | `IPKF` — HeartGold, France, rev 0 | `DBA64620A959D5F69ED1CF3E43FCFCF2786D417E` |

## ROM layout

- ARM9: ROM `0x4000`, RAM `0x02000000`, stored size `0xBA378` (SS) / `0xBA370` (HG),
  **BLZ-compressed**, decompresses to `0x111F18` in both.
- `MODULE_PARAMS` at RAM `0x02000BA0` (file offset `0xBA0`), magic `0xDEC00621` at `+0x1C`:
  - `+0x08` autoload_start `0x02111880`
  - `+0x0C` static_bss_start `0x02111880`
  - `+0x10` static_bss_end `0x021E5920`
  - `+0x14` **compressed_static_end** `0x020BA378` → set to `0` to store ARM9 uncompressed
- Overlay table ROM `0xBE400`, **129 overlays**, all BLZ-compressed except ov35 / ov124.
  Overlays load from RAM `0x021E5920` — directly after ARM9 bss, so **ARM9 cannot be grown**.
- Filesystem: 513 files, opaque `/a/x/y/z` NARC layout.

## HG vs SS are nearly the same binary

This is the single most useful discovery — the patch is portable for free.

- Decompressed ARM9s are the **same length** and differ by **2184 bytes (0.195%)**;
  longest identical run 205,808 bytes. **ARM9 code is at identical addresses in both.**
- All **129 overlays have identical RAM bases**; **114 are byte-identical**.
  Overlay 10 (battle action select) is byte-identical. Overlay 12 (battle core) differs
  by 7 bytes. Only ov18 (89%) and ov74 (48%) differ substantially.

## Display routing

`POWCNT1` = `0x04000304`, **bit 15**:
- `1` = 2D engine A → **upper** LCD (stock: overworld, battle scene)
- `0` = 2D engine A → lower LCD, i.e. engine B (the touch UI) drives the **upper** LCD

The address can't be reached by a small immediate offset (ARM `STRH` imm is 8-bit, Thumb
5-bit; `0x304` exceeds both), so it always sits in a literal pool — which makes every use
site findable by scanning for the literal and then the PC-relative `LDR` that reaches it.

**110 reference sites** exist across ARM9 and 26 overlays. Classification:

| count | what it does |
|---|---|
| 42 | **sets** bit 15 (engine A → top) |
| 45 | writes POWCNT1 without touching bit 15 |
| 18 | loads the address, no store in window |
| 4 | ARM-mode, bit 0 = LCD power (`GX_DispOn` / `GX_IsDispOn` at `0x020DB6EC`, `0x020DB794`) |
| 1 | masked field write during boot graphics init (`0x0201A20A`) |

The game **re-asserts the stock routing at every app transition**, which is why an
external emulator/cheat swap does not stick across screens.

### The flip

The compiler builds the `0x8000` mask by shifting the address register itself
(`0x04000304 >> 11 == 0x8000`), giving a very recognisable idiom:

```
ldr  r2, =0x04000304   ; POWCNT1
ldrh r1, [r2]          ; current value
lsrs r0, r2, #11       ; r0 = 0x8000
orrs r0, r1            ; set bit 15          (0x4308)
strh r0, [r2]          ; commit              (0x8010)
```

To route engine B to the top instead we want `current & ~0x8000`:

```
bics r1, r0            ; 0x4381
strh r1, [r2]          ; 0x8011
```

**Two halfword edits per site. No new code, no hooks, no free space required.**
Register numbers vary per site, so `onescreen/sites.py` decodes each one and
computes the replacement encodings:

```
new_alu  = 0x4380 | (mask_reg << 3) | value_reg     ; bics rV, rM
new_strh = 0x8000 | (addr_reg << 3) | value_reg     ; strh rV, [rA]
```

**39 of the 42 set-sites decode cleanly** and are flippable, spread over ARM9 (4) and
25 overlays. Verified in melonDS: flipping all 39 boots at full speed and visibly moves
the touch UI to the top screen (`out/proof_swap.png`).

## Useful ARM9 addresses (identical in IPGF and IPKF)

| address | what |
|---|---|
| `0x02000CA4` | `NitroMain` |
| `0x02000DB0` | **main loop head** (back-edge `b` at `0x02000E46`) |
| `0x021D112C` | main state block (`r4` in the loop) |
| `0x021D1164` | `[r4+0x38]` processed held-keys mask, 1 = pressed (soft reset checks `0x30C` = L+R+START+SELECT) |
| `0x021D112C+0x00/+0x04` | current app callback + argument, dispatched via `blx` each frame |
| `0x0201A200` | boot graphics init (called once from `NitroMain`) |

These give a per-frame hook and an "which app is running" signal if dynamic swapping is
needed later (it is, for battles — see below).

## Overlay identities

From pret/pokeheartgold's `main.lsf`, which uses the **same overlay numbering as the
retail ROM** (verified: ov12 = battle system, ov1 = field). Only overlays containing a
flippable site are listed; see `onescreen/table.py` for the machine-readable table.

| ov | identity | v1 intent |
|---|---|---|
| 5, 15, 37, 56, 68, 71, 73, 82, 83, 85, 102, 108, 109, 113 | unidentified in the decomp | FLIP |
| 12 | **battle system** — commands, HP bars, input, cursors | **KEEP** |
| 17 | berry pots app | FLIP |
| 51 | trainer card — main interface | FLIP |
| 52 | trainer card — **signature (stylus drawing)** | **TOUCH** |
| 57, 59, 70, 72 | battle-related systems | FLIP |
| 74 | **main menu application** | FLIP |
| 80 | battle frontier | FLIP |
| 110 | **Ruins of Alph sliding puzzle (stylus)** | **TOUCH** |

**The field/overworld uses overlays 1, 2, 3 and 27 — none of which contain a flippable
site.** That is why blanket-flipping the overlays cannot disturb the overworld, and it
means the overworld's routing is established elsewhere (one of the 4 ARM9 sites, or
inherited from boot). The 4 ARM9 sites are left alone in v1.

## The two families, and the global display-select flag

Apps may draw their interactive UI on **either** engine and then route that engine to
the bottom screen. So there are two opposite idioms, and a correct patch must handle both:

| family | idiom | meaning | flip |
|---|---|---|---|
| **SET** (39 sites) | `lsrs rM,rA,#11` / `orrs` / `strh` | UI on engine B, bit15=1 → UI bottom | `orrs`→`bics` + change `strh` source |
| **CLR** (43 sites) | `ldr rM,=0xFFFF7FFF` / `ands` / `strh` | UI on engine **A**, bit15=0 → UI bottom | literal→`0x00008000`, `ands`→`orrs` |

v1 only handled SET, which is why the Bag flipped but the Pokédex/Pokégear did not.
The CLR literal is only rewritten when exactly one LDR in the module references it.

**Not every app sets POWCNT1 itself.** Many call a shared helper:

- **`0x02022D3C` — apply display select.** Reads a global flag byte and applies bit 15:
  ```
  ldr r0,=0x021D118C ; ldr r2,=POWCNT1 ; ldrb r0,[r0,#9]
  cmp r0,#0 ; bne .clear
  ... orrs (bit15=1, engine A top) ...
  .clear: ... ands 0xFFFF7FFF (bit15=0, engine A bottom) ...
  ```
  **Global flag byte: `0x021D1195`** (= `0x021D118C + 9`), initialised to 0 by the boot
  graphics init at `0x0201A30E`. Called from ~90 sites, **including ov001 (the field)**.
- **`0x02022D24`** — enables the sub engine's display (`DISPCNT_B |= 0x10000`), 33 callers.

Consequence: the field and several apps share this one helper and one flag, so no purely
static edit can flip one without the other. Apps that neither set POWCNT1 nor call the
helper simply **inherit** the field's routing — this is why the party screen stays on the
bottom no matter which sites are flipped.

Flipping the 4 ARM9 sites was tested (`out/ipgf-arm9only.nds`): it swaps the **overworld**
(touch menu on top, world below), confirming the field's routing is established there.
Excluding the boot-init site alone does not change that.

## Battle screen layout (confirmed in-game)

- **Top screen:** battle scene, both HP bars, **and the message box** ("Que doit faire
  KAIMINUS ?"). The plan's open question is settled — battle narration is on the top.
- **Bottom screen:** command buttons (ATTAQUE / SAC / FUITE / POKéMON), then the move list.

This confirms the swap cadence is viable: while choosing an action the top screen carries
only a prompt you don't need to read, and while a turn resolves the bottom menu is idle.

## Battle state, measured

At the rival battle's action-select menu (`out/ipgf-v4.nds`, rival save):

| what | value |
|---|---|
| app callback `[0x021D112C]` | `0x02239751` — inside **ov12** (`0x022378E0`..`0x0226EC60`) |
| `POWCNT1` | `0x820F` — bit 15 set, battle scene on top |
| `[0x0221BE40]` | `0xB082B5F8 0x20D51C06 0x1C0D9201 0x1C1A0080` |

Those four words are an **exact byte match for overlay 10** as stored in the ROM
(`tools/whichov.py` disambiguates the six overlays sharing that base: ov7, ov8, ov9,
ov10, ov63, ov65). So **ov10 is confirmed resident during action-select**, and the plan of
swapping on its load/unload is sound.

After the battle ends, `[0x0221BE40]` reads all zeros — the region is cleared on unload,
which means a residency check is viable in principle. Not yet confirmed for the
*mid-battle* unload (turn resolution), which is the case that actually matters.

### Hook point still to find

- `find_template.py 10` finds **no** OverlayManagerTemplate for ov10, so it is not launched
  through the app framework the way the menu apps are.
- `find_loader.py` (rank BL targets by variety of small r0 constants) produced false
  positives: `0x02037AC0` / `0x02037B38` turned out to be field/script state accessors on
  the struct at `*(0x021D416C)`, not overlay loaders.

Two options remain: find the real loader (a GDB breakpoint on the ov10 RAM range would
identify it directly), or poll ov10 residency per frame from the main loop at `0x02000DB0`
and call `OneScreen_SetSwap`.

## Testing note: reaching battles

Wild encounters could not be triggered by automation (100+ paced steps, no encounter). The
working approach is the user's save placed one step from the **rival battle** — walk right,
mash A through the dialogue. Deterministic and repeatable.

## Battles: solved with an in-ROM toggle (v5)

**ov10 is the trainer AI, not the menu.** The decomp lists `OVY_12` as owning "commands,
HP bars, input, cursors", so the action-select menu lives *inside* ov12 and there is no
overlay boundary to hook. ov10 merely happens to be resident across the turn, which made
it look like a usable signal. It is not.

What shipped instead: `OneScreen_Frame` in ITCM, reached by replacing the main loop's
`bl 0x0200110C` at **`0x02000DB0`** with a call to our code, which runs the original and
then polls the pad. **L+R toggles POWCNT1 bit 15.**

- Pad state is read from `0x021D1164` (1 = pressed); rising-edge latched in an ITCM word.
- `inject.py:patch_main_loop` asserts the site really holds `bl 0x0200110C` before
  patching, so a wrong address fails the build rather than corrupting the ROM. This check
  passes for **both** IPGF and IPKF, confirming the main loop is at the same address.
- The toggle persists until something else writes POWCNT1 — which is exactly right,
  because each app asserts its own routing on entry and **nothing re-asserts it mid-battle**.

Verified in the rival battle: L+R brings ATTAQUE/SAC/FUITE/POKéMON to the top screen, and
the move list (Griffe NORMAL PP 35/35, Groz'Yeux NORMAL PP 30/30, ANNULER) is fully
readable and D-pad navigable there. Turn resolution keeps the swap, so it is two presses
per turn.

## Savestate diffing (works well — use this, not GDB)

`tools/savestate.py` locates the 4 MB main-RAM block inside a melonDS savestate by
searching for the first bytes of `build/<code>/arm9_dec.bin` (main RAM starts at
`0x02000000` and the ARM9 static section is loaded there verbatim). Main RAM sits at file
offset `0x24` in melonDS 1.1 states. This sidesteps both GDB limits entirely.

Diffing `ipgf-v5.ml1` (action-select) against `ipgf-v5.ml2` (turn resolution), same battle,
same run: 93,834 differing bytes overall, but only **43 bytes** inside
`0x022C0000..0x022C1000`, and the interesting one is a 70-byte region at `0x022C0556`
that goes from **all zeros to structured data**:

```
ml1  0x022c0554:  0x00000000 0x00000000 0x00000000 ...
ml2  0x022c0554:  0x00040000 0x00000001 0x00040002 0x0225000e ...
```

That is battle context + `0x2E8` (context base `0x022C026C` in that run). It reads as a
battle script / text-command queue that fills as the turn plays out.

**Candidate rule:** `ctx = *(u32*)0x021D1130; action_select = (*(u32*)(ctx + 0x2E8) == 0)`.

### Critical constraint

The battle context is **heap-allocated and its address changes between runs** — measured
`0x022C026C` in the savestates and `0x022C02B0` in a later launch. Any detection must
dereference `0x021D1130`; a hardcoded `0x022C05xx` is meaningless. (This also invalidated
one probe: the fixed window read the wrong offset once ctx shifted by `0x44`.)

### Result: rejected

A third savestate (`ml3`, turn 2 action-select, same run, same context `0x022C026C`)
showed that region **byte-identical to `ml2`**. The queue is cumulative, not per-turn, so
the rule would have worked on turn 1 only.

## Triangulation, and why the second candidate also failed

Three states make a much better filter than two: with `ml1` and `ml3` both at
action-select and `ml2` mid-turn, a genuine state variable satisfies
**`ml1 == ml3` and `ml2 != ml1`** — anything that merely counts, accumulates or animates
differs between `ml1` and `ml3` too. `tools/savestate.py triangulate` implements this.

It surfaced candidates at **fixed ARM9 BSS addresses** (no heap pointer chasing needed),
the cleanest looking being `0x021DD440`: `0` at both menus, `1` during resolution.

**It is a coincidence.** Probed live at a turn-1 action-select it reads **`1`**, where the
savestate had `0`. The reason is simple arithmetic: **68,535 bytes** satisfy the
three-state constraint, so false positives are guaranteed. Three samples is not enough
evidence, however clean a byte looks.

**What would actually work:** repeat the triangulation across **several different
battles** (different opponents, different turns, ideally a wild battle and a trainer
battle) and intersect the candidate sets. A real state variable survives every
intersection; coincidences die fast. That needs ~6 savestates rather than 3.

The auto-swap code is written and gated behind `build.py --auto-battle`
(`--defsym ENABLE_AUTO_BATTLE=1`), **off by default**, so the shipped build is the
verified manual-toggle one. Only the state byte is wrong; the surrounding design — gate
on the app callback being inside ov12, edge-trigger so a manual override survives — is
sound and reusable once a real state variable is found.

## Automatic battle swapping: SOLVED

`BATTLE_STATE = 0x021E17C4`, a fixed ARM9 BSS address. **1 = awaiting the player's
command, 2 = turn executing.** A second copy at `+0x2C` behaves identically, which is what
a per-battler state array looks like.

How it was found, after two failed guesses:

1. **Groups, not pairs.** Savestates from **three different battles** — five "waiting"
   states (including the move-select submenu) against three "executing" states. A real
   state variable is constant within each group and differs between them, across
   different opponents and turns. `savestate.py intersect` does this.
2. **Reject heap churn.** That still left 61,188 bytes, because whole blocks read as fill
   (`0xAB`/`0xBB`/`0xFF`) while idle and as allocated data mid-turn — a perfect
   correlation that is useless. Two filters fixed it:
   - both values must be small (`<= 32`) — state enums are, fill bytes are not
   - the byte must be **isolated** (no other hit within 8 bytes) — a state variable sits
     alone; heap blocks change in long runs

   **61,188 → 11**, of which 5 were at fixed (non-heap) addresses.
3. **Confirm live.** All 5 survived a GDB probe in a *fourth* battle that was not in the
   sample. `0x021E17C4` was chosen for the cleanest semantics.

### Returning from a submenu (v15)

Two bugs of the same shape — coming *back* to a root menu:

- **Battle.** `bt_committed` is set by A and was only cleared on a phase change, so once
  you had been into the move list or bag the idle timeout never re-armed and the menu
  stayed up forever. **B now clears the commit**, since B is exactly "go back a level".
- **Overworld.** Entering a sub-app (party, bag, Pokédex) cleared `menu_swapped`, so on
  return the X menu was still open but we had forgotten we swapped for it — and the field
  re-applies its own layout on re-entry, putting the menu back on the bottom. The latch is
  now **kept** across sub-apps and the routing re-applied every frame while the menu is
  open. It is still dropped on entering a **battle**, where the battle logic owns the
  screens.

### Sub-screens opened from the battle menu (v14)

The bag and party opened *from inside a battle* stayed on the bottom. Two separate causes,
both worth recording:

1. **The state variable was conflating two situations.** `0x02111930` reads `0x06` both
   when a command is confirmed *and* while a sub-screen is open, so the code decided the
   turn was executing and threw the scene back on top. `0x021D0E28` distinguishes them
   (`0x08` sub-screen vs `0x07` confirmed) — see the constant block in `src/hook.s`.
   Testing it **negatively** (`!= 0x07`) also covers waiting sub-states we never
   enumerated, which is what broke the earlier `== 0x0A` test.
2. **A one-shot swap is not enough.** Those sub-screens re-assert the display routing
   themselves as they open, undoing our swap. The routing is now **re-applied every frame**
   while the menu is up. L+R clears `bt_menu_up` so a manual override is still not fought.

Note the raw state is collapsed to a single "executing" bit *before* the
transition check. Without that, moving between waiting sub-states (`0x0A` → `0x08`) counts
as a phase change and resets the interaction state, dropping the menu the instant you
open the bag.

Verified: bag category screen, item list and party list all render on the top screen
inside a battle.

### Picking the right one of the five: timing matters (v12)

The five surviving candidates all agree on *what* the phase is, but not on *when* they
change. Probed 150 ms after confirming a move:

| candidate | value | |
|---|---|---|
| `0x021E17C4` | still `1` (menu) | **late** — only flips once the turn machinery starts |
| `0x02134F15` | still `0x02` | late |
| `0x021E17F0` | still `1` | late |
| `0x021D0E28` | already `0x07` | early |
| `0x02111930` | already `0x06` | early |

A late variable makes the swap look wrong: the text and animation are already under way
before the screen changes.

`0x021D0E28` was tried and **rejected** — it is too fine-grained, taking at least three
values inside a battle (`0x0A`, `0x08`, `0x07`). A single "is it the menu" comparison
misses sub-states, and the menu silently stops appearing.

**`0x02111930` is the one in use:** `0x07` through every awaiting-a-command state
including the move list, flipping to `0x06` the instant a command is confirmed. It also
reads `0x07` outside battle, which is harmless because everything is gated on the app
living in overlay 12.

Also worth recording: **do not try to guess which A press confirms the command.** An
attempt to fire on "the second A" swapped away from the move list, because the number of
presses varies with whether the cursor was moved first, backed out with B, or SAC/POKéMON
was chosen. The state variable already flips on confirmation — let it do the work.

### On-demand, not forced (v9)

Swapping the moment the game asks for an action turned out to be the wrong call: it hides
the battle scene exactly when you want to read the result of the last turn. The menu now
comes up only when you reach for it.

| condition | top screen |
|---|---|
| phase 2 (turn executing) | battle scene, forced |
| phase 1 entered | unchanged — deliberately no swap |
| D-pad or A newly pressed | command menu |
| `IDLE_FRAMES` (120 ≈ 2 s) with no input, uncommitted | battle scene |
| A pressed | committed: timeout disabled, menu stays |

A is a trigger as well as the D-pad because the cursor starts on ATTAQUE — pressing A
without moving first would open the move list unseen on the bottom screen.

All five behaviours verified in-game on a live trainer battle.

The lesson worth keeping: **three savestates from one battle is not evidence.** 68,535
bytes passed that test and the one that looked cleanest was still a coincidence.

### The A press that pinned the menu

Reported from play: mash A to skip the battle intro and the command menu comes up
immediately and then never times out — the only way to get the scene back was to go into a
submenu and press B.

`bt_committed` was the cause. It exists so the move list does not vanish while you read it,
and it was set by *any* A press while awaiting a command, cleared only by B or a phase
change. But "awaiting a command" is really "overlay 10 is resident"
([see above](#the-battle-variable-identified)), and overlay 10 loads while the intro text
is still playing. So an A press eaten by the text set a commit for a menu that did not
exist yet, and nothing later cleared it.

The fix is to make the rule mean what it says: **A is a selection only if there was a menu
on screen to select from.** An A press with no menu up just brings the menu up, exactly
like the D-pad. A second A — now with the menu visibly up — commits.

Belt and braces on top of that, the timeout is also suppressed whenever the phase reads
`8` (a sub-screen is open), because browsing the bag or the party is exactly where long
pauses are legitimate. That comes from the game's own state, so it holds even when the
commit flag is wrong.

The residual case: press A once from the battle scene, then sit reading the move list for
over a second, and it will step aside. Any button brings it straight back.

## Pokédex area map — solved with the decomp, after RAM diffing failed twice

Wanted: at the per-Pokémon detail level, put the **area map** on the top screen, but only
there — not on the species grid. They share one app callback (`0x021E5C5D`, inside ov18)
and both read `POWCNT1 = 0x820F`, so `app_table` cannot separate them.

**Two RAM-diff candidates were tried and both were noise:**

| candidate | savestates said | live reality |
|---|---|---|
| `0x02111930` | `0x06` grid / `0x07` detail | reads `0x07` **at the grid too** |
| `0x021E3E8B` | `0x04` grid / `0x02` detail | `0x04` at the grid once, `0x02` at the grid later |

Both are transient globals that merely happened to be settled when the savestates were
taken. Intersecting four savestates still left 159 isolated candidates — far too many.

### What actually worked

pret/pokeheartgold has the Pokédex decompiled (`src/application/pokedex/`), which gives the
real structure instead of a guess:

```c
struct OverlayManager { OverlayManagerTemplate template;  // init/exec/exit/ovy_id
                        int exec_state;                   // +0x10
                        int proc_state;                   // +0x14
                        void *args; void *data; ... };
```

and `OverlayManager_Run` calls `template.exec(man, &man->proc_state)`. **The screen level
is `proc_state`, handed to the app every frame.** Searching RAM for an OverlayManager with
`ovy_id == 18` confirmed it:

| level | `proc_state` |
|---|---|
| species grid | **11** |
| detail level (area map) | **69** |

Consistent across four savestates covering two different Pokémon, and `69` has its own
struct in the decomp (`PokedexAppData_UnkSub0868_State69`), which corroborates it.

### Reaching it at runtime

The manager is heap-allocated and no fixed global points at it (checked two levels of
back-references — all heap). So instead of chasing pointers, the patcher **takes over the
`exec` pointer** in the Pokédex's `OverlayManagerTemplate`, which lives in ARM9 *static*
data. The framework then calls our trampoline with `r1 = &proc_state`, and it tail-calls
the real exec. No pointer chasing, no per-frame scanning.

The template is located **structurally** — three pointers into overlay 18 followed by the
id — so it is region-independent. Exactly one match per ROM:

| ROM | template | exec |
|---|---|---|
| SoulSilver FR | `0x020FA268` | `0x021E5B81` |
| HeartGold FR | `0x020FA268` | `0x021E5B85` |
| HeartGold US | `0x020FA284` | `0x021E5B65` |

Verified in-game: the area map renders on the top screen, and backing out restores the
species grid. This technique generalises to any OverlayManager application.

### The fade-in flash, and why 69 alone was the wrong rule

Swapping on state 69 made the map fade in on the **bottom** screen and then jump across
once it was fully visible. The menus never did that, so the difference was worth chasing.

69 is not where the map is built. `PokedexApp_MainSeq_68` builds it, starts a fade in
**from black**, and returns `MainSeq_03` — the shared "wait for the palette fade" state,
which loops back to whatever `unk_085C` names. Only once the fade has finished does 68
return 69. So the entire visible fade-in happens under states **68 and 03**, and swapping
at 69 was swapping *after* the animation the player was watching.

Two corrections came out of that:

- **The map screen is a state range, not just 69.** 69 is the idle screen, 70 fades back
  out, and 71–75 handle scrolling between maps and the sub-interactions — every one of
  them returns to 69. 76 begins the next tab.
- **02 and 03 are shared fade waits reached from both sides**, so they say nothing about
  which screen is up and must not be read as "not the map". They hold the current routing.

### …and why 68 alone still flashed

Acting on 68 was still wrong, and play-testing caught it: the flash got shorter but did
not go away. **Which state builds the map depends on how you arrived.**

| route | states |
|---|---|
| from another tab | 91 (or 78 / 81) fades out → 03 → returns **68** |
| from the species grid | 64 / 15 fades out → 03 → returns **66** |

and `MainSeq_66` does its own setup and then **tail-calls `PokedexApp_MainSeq_68` directly**:

```c
static int PokedexApp_MainSeq_66(PokedexAppData *app) {
    ...
    return PokedexApp_MainSeq_68(app);
}
```

So on the grid route the map is built and the fade started while `proc_state` still reads
**66**, and the value 68 never appears until the fade has already finished — which is
precisely the frame we were swapping on. Hence the range starts at 66. Both routes into 66
come after a fade to black (one also calls `ZeroPalettesByBitmask`), so swapping there is
invisible.

**67 also had to become a hold state.** It is the shared "fade this tab out and go back to
the list" state, reached from whichever tab was open, so picking a side there threw the map
to the bottom screen before it had faded.

The general lesson, now twice: **a state machine's screen identity is not a single value,
and a tail call between handlers means a state you expect to see may never be written.**
Read the transitions, not just the resting states.

Acting on 68 also makes the swap *invisible*: 68 fades in from black, so the previous
screen has already faded out and both engines are black at the moment of the flip. That is
exactly why the menus never flashed — they were already being swapped while black. **The
general rule: swap during the game's own fade, not after it.**

The routing is also re-applied on every state change rather than only when the side flips,
because the app reconfigures the display as it builds each screen.

### The battle variable, identified

`BATTLE_STATE` (FR `0x021D0E28`) was derived empirically and shipped as a magic number.
The decomp names it — not where the earlier search looked (`asm/unk_0200B150.s` is still
raw assembly), but in `src/poke_overlay.c`:

```c
typedef struct PMiLoadedOverlay { FSOverlayID id; BOOL active; };
static PMiLoadedOverlay sOverlayRegions[OVY_REGION_NUM][OVY_MAX_PER_REGION];
```

3 regions × 8 slots × 8 bytes of BSS, tracking which overlays are resident. Dumping
`0x021D0E10` onward from four savestates shows the array exactly:

| | slot 0 | slot 1 | slot 2 | **slot 3** |
|---|---|---|---|---|
| in battle | `12`, active | `18`, active | `6`, active | **`10`, active** |
| in the Pokédex | `18`, active | `2`, stale | `3`, stale | **`27`, stale** |

So `0x021D0E28` is `sOverlayRegions[OVY_REGION_MAIN][3].id` — the overlay id occupying
main-region slot 3. The battle loads a different overlay per phase, which is why it tracks
the phase: `10` = the command menu, `8` = a sub-screen, `7` = the turn executing. `27` is
just a stale id in an inactive slot, which is what "outside battle" was really measuring.

**This closes the US gap.** The array is BSS so it cannot be found by shape, but exactly
one ARM9 literal points at it, at a fixed *code* address (`0x0200713C`). Reading that
literal gives the base per ROM:

| ROM | `sOverlayRegions` | slot 3 |
|---|---|---|
| SoulSilver FR / HeartGold FR | `0x021D0E10` | `0x021D0E28` |
| HeartGold US | `0x021D0DF0` | `0x021D0E08` |

The US value matches what the −0x20 delta predicted, so nothing changes in behaviour — but
it is now **read from the ROM instead of inferred**, and it doubles as an independent
second measurement of the region shift, which the patcher cross-checks against the one it
gets from the main loop's literal.

**The caveat this exposed:** the value says which overlay is *resident*, not whether the
menu is accepting input. Overlay 10 is already loaded while the battle intro text is still
playing, so "awaiting a command" goes true early — see
[The A press that pinned the menu](#the-a-press-that-pinned-the-menu).

### Lesson

**A candidate is not confirmed until it has been probed live in a state that was not part
of the sample.** That check caught all four bad candidates; savestate intersection alone
caught none of them. Where the decomp has coverage, prefer its structure over any
statistical search.

## PC box — savestates, because the decomp does not reach it

Overlay 14 is one of the 75 still raw assembly in pret. `PCBox_Main` exists as a symbol
(`asm/overlay_14.s`, `; 0x021E596C`) but there is no state machine, no state constants, and
nothing like the `POKEDEXAPP_MAINSEQ_*` enum that made the Pokédex tractable. So the screen
levels had to come from observation.

The method that worked for the Pokédex works without any source: scan a savestate's RAM for
an `OverlayManager` whose `template.ovy_id == 14` and whose three function pointers land
inside overlay 14's RAM range, then read `exec_state` (+0x10) and `proc_state` (+0x14).
Seven savestates, one live manager at `0x022A9C10`:

| savestate | `exec_state` | `proc_state` |
|---|---|---|
| PC option list, before entering | — | **no manager exists** |
| inside a box, cursor on a Pokémon | 2 | 81 |
| inside a box, holding a Pokémon | 2 | 115 |
| item storage | 2 | 117 |
| back on the option list | — | **no manager exists** |
| fading in | 2 | 0 |
| fading out | 3 | 0 |

The useful result is the one that is absent. **The PC option list has no overlay-14 manager
at all**, checked both before entering and after backing out — it is a field menu, and the
app only exists once you are inside. So the whole of overlay 14 is "managing the box", every
screen in it wants engine B on top, and there is no per-state rule to get wrong. The
trampoline just applies the swap on every call.

### The direction was wrong, and inference kept getting it backwards

Two shipped attempts forced the box towards engine B, on the reasonable-sounding
assumption that the touch UI is always on engine B. It is not. Disassembling overlay 14's
single `POWCNT1` site in the stock ROM settles it in one look:

| | instruction | effect |
|---|---|---|
| stock | `ldr r0,=0xFFFF7FFF ; ands r0,r1` | clears bit 15 -> **engine B on top** |
| patched | `ldr r0,=0x00008000 ; orrs r0,r1` | sets bit 15 -> **engine A on top** |

So stock HGSS puts engine B on the PC's *top* screen, which means the box grid — the half
you actually operate — is drawn on **engine A**. The static site flip already turns that
into "grid on top" and needs no help at all; forcing engine B up shoved the grid back down
and undid it.

**`SetSwap(1)` means "engine A to the bottom", not "bring the touch UI up".** The two
coincide for most apps only because most apps happen to draw their touch UI on engine B.
Establish which engine an app actually draws on — by disassembling its site — before
choosing a value. Several rounds of otherwise-sound reasoning about savestates could not
substitute for that one disassembly.

### Ordering: why the first attempt did nothing at all

Swapping before tail-calling the app — the way the Pokédex trampoline does — had **no
visible effect whatsoever**. The reason is ordering, and the evidence is two measurements:

- overlay 14 contains exactly **one** `POWCNT1` site, so the app is not fighting us with a
  stream of its own writes;
- `gSystem.screensFlipped` reads **0** in all seven PC savestates, and `GfGfx_SwapDisplay`
  turns that into "engine A on top".

So anything the app calls that routes screens puts the box back on the bottom — and because
our write came *first*, the app always had the last word. The Pokédex gets away with a
pre-exec swap only because it does not re-route.

The fix is to run the app first and set the routing afterwards, plus a two-frame countdown
that re-applies it from `OneScreen_Frame`, the same place the battle logic writes from,
which is known to win. The cost is that L+R does not stick while the PC is open.

**The general rule: when an app re-routes screens, your write has to be the last one in the
frame — a trampoline that swaps before tail-calling is the wrong order.**

Coming out is self-healing: the field re-asserts its own layout on return, the same reason
the overworld menu needed a latch.

The template resolves structurally in every ROM, and US lands on `0x021E596D` — exactly the
`0x021E596C` the decomp's assembly listing gives for `PCBox_Main`, with the Thumb bit. A
free cross-check that the structural search finds the right thing.

## Field script menus — the PC option list, and everything like it

The PC option list is not part of the PC app at all (that was the savestate result above).
It is a **field script menu**, drawn on the touch screen by the running script inside the
field app — the same mechanism as shop lists and NPC yes/no choices. There is no app
transition to detect and no `POWCNT1` write of our own to catch.

pret gives the signal directly. `FieldSystem` (`include/field_system.h`) has:

```c
struct FieldSystem { FieldProcessManager *processManager;   // +0x00
                     ... ; int bottomScreenType;            // +0x18
                     int unk1C; ... };                      // +0x1C
```

and `ScrCmd_TouchscreenMenuHide` sets `unk1C = 3` when a script takes the bottom screen,
while `ScrCmd_TouchscreenMenuShow` sets it back to `0` for the normal icon bar. The live
`FieldSystem` hangs off `sFieldSysPtr`, the file-static in `field_system.c`.

Finding `sFieldSysPtr` was a search with a real control, unlike the two Pokédex candidates
that failed. Scanning every 4-byte-aligned word of ARM9 BSS for a pointer that is **stable
across all seven savestates** and whose `+0x1C` reads 3 in both option-list states left
**exactly one** hit: `0x021D4178` → `0x022A027C`. The struct there is unmistakable — six
heap pointers, then two small ints, then more heap pointers, exactly the decomp's layout.

Then the rule that caught every earlier bad candidate: **probe out of sample.** Reading the
same fixed address in six savestates from *different sessions and different builds*:

| savestate | `unk1C` |
|---|---|
| all seven PC states | **3** |
| Pokédex ×2, battle, overworld ×2, name entry | **0** |

Clean separation on both sides, from data that was never part of the search.

Six ARM9 literals point at `sFieldSysPtr`, at the **same six code addresses** in all three
ROMs, each holding its own region's value — so the patcher reads it per ROM
(FR `0x021D4178`, US `0x021D4158`) and cross-checks the shift, as with `sOverlayRegions`.

The hook tests **non-zero** rather than `== 3`: any non-default mode means a script has put
something on the bottom screen the player needs. Applied every frame while it is up, and
the world goes back when it clears.

This is the broadest fix in the project so far — it covers the PC option list, shop menus
and NPC choice menus in one rule.

## Flying — and reading the hook's own mind

Selecting a destination on the Town Map left the whole flight animation on the bottom
screen, and it only corrected itself much later.

Savestates through the sequence show the shape of it: the Town Map app is live before the
press (overlay 101, `exec_state 2`), reads `exec_state 3` immediately after — the app
exiting — and is gone by mid-animation with `gSystem.vBlankIntr` back to the field. **So
the flight animation is drawn by the field, after the Town Map tears down.**

Two things then ruled out every state-based approach:

- the arrived-but-wrong and arrived-and-corrected savestates are **identical field for
  field**, differing only in `POWCNT1`;
- `location->mapId` only changes on arrival, far too late for "swap when I press A".

### The actual cause, found by reading our own variables

A first fix — restore the world on the app→field transition — changed nothing, and the
reason was invisible in game state because it was in *our* state.

The payload lives in ITCM, which is not part of the main-RAM block `savestate.py` extracts.
But it begins with the ASCII signature `1SGS`, so it can be found by searching the raw
savestate file. `python tools/savestate.py hook state.mln` does exactly that, and it said:

| savestate | `menu_swapped` |
|---|---|
| town map, mid-flight, arrived-wrong | **1** |
| after it corrected | 0 |

Flying is reached *through* the X menu, and that latch is deliberately kept across
sub-apps so a trip into the bag and back leaves the menu on top. But flying does not come
back to the menu, it comes back to the world — so `Poll` was re-applying "menu on top"
every frame, which is what put the animation on the bottom screen, and the new restore
code sat behind that gate and never ran.

The fix hooks the fly map's template and watches for it to **stop** being called, which is
the frame after you confirm. If the field has taken over by then, the latch is dropped and
the world is forced up for half a second. Backing out of the town map into the Pokégear
proper is excluded by that same check.

**The lesson: when a fix has no effect, suspect your own state before the game's.** Game
state had nothing to say here; one look at `menu_swapped` had the whole answer.

## The field's task manager — and what it can and cannot tell you

Reaching the field's running task needs no searching:

```c
struct TaskManager { TaskManager *prev; TaskFunc func; u32 state; void *env;
                     u32 unk10; void *unk14; FieldSystem *fieldSystem; ... };
```

via `sFieldSysPtr -> fieldSystem->taskman` (+0x10), and the struct **confirms itself** —
`+0x18` reads back the same `FieldSystem` pointer we started from. Three savestates:

| state | `taskman` | `taskman->func` |
|---|---|---|
| X menu open | `0x022C01D8` | `0x0203BEF1` — ARM9, i.e. `Task_StartMenu` |
| no menu | **NULL** | — |
| after Dig | `0x022C01D8` | `0x0224C3CD` — an **overlay** address, a script task |

Two facts are safe to use, and only two:

- **`taskman == NULL`** means the field is idle, so a press of X really will open the
  menu. That is the game's own gate (`src/field_control.c` only reaches `StartMenu_Init`
  when no task is running), which is exactly why a ladder swallows the press.
- **an overlay-resident `func`** means a script owns the field. Scripts live in overlays;
  the menu lives in ARM9.

### The mistake worth recording

The tempting third reading — "`func` is in ARM9, therefore the menu is open" — is **wrong**,
and shipping it broke more than it fixed: the cave-name card and the flight sequence are
ARM9 field tasks too, so the menu got forced on top of both. ARM9 means "not a script",
nothing more.

The corrected design uses each fact only in the direction it supports:

| symptom | rule |
|---|---|
| X on a ladder swapped with no menu | accept X only if **last frame's** `taskman` was NULL |
| Dig / Escape Rope kept the menu latched | an overlay task appearing **clears** the latch |

The clearing rule can only ever lower the latch, never raise it, so it cannot put the menu
over a cave card or a flight however wrong its premise turns out to be. **A rule that can
only remove behaviour is far safer to ship than one that can add it** — the broad version
failed in ways play-testing surfaced one at a time, which is the expensive way to find out.

Reading `taskman` from the frame *before* the press also avoids racing the game: our hook
runs inside the same main loop that handles input, so by the time we see the X press the
menu task may already exist.

## Regions: what actually differs

Measured between French HeartGold (`IPKF`) and US HeartGold (`IPKE`):

| | result |
|---|---|
| Display-routing sites found | **87 in both — 42 SET + 45 CLR, identical** |
| ARM9 code anchors (`0x02022D40`, `0x02000DB8`, `0x02000E32`) | **same address in both** |
| Name-entry app at `0x02083140` | **byte-identical** (`b508 f79d fa6b f788`) |
| Main-loop hook site `0x02000DB0` | identical (`f000 f9ac`) |
| ITCM autoload block | identical (`0x01FF8000`, size `0x620`) |
| ARM9 bytes differing | 7.08% — all in *data*, not code layout |
| Overlay bases, `static_bss_start`, `bss_end` | shifted uniformly by **−0x20** |

**ARM9 code addresses are identical across regions; only data, BSS and overlay bases
move, and they move together.** That is why the static half of the patch needed no region
work at all: `sites.py` finds sites by instruction shape, and `table.py`'s exceptions are
overlay *numbers* plus two ARM9 *code* addresses (`0x02022D3E`, `0x0201A2A2` — both
confirmed to hold a POWCNT1 LDR in US as well).

### How the hook is region-resolved

Rather than a per-region address table, `onescreen/regions.py` derives everything from
the ROM (see `OneScreen_Config` in `src/hook.s`):

| value | source |
|---|---|
| `app_callback` | the literal the main loop loads into r4, read at the fixed code address `0x02000DA6` |
| `pad_held` | `app_callback + 0x38` |
| `field_callback` | overlay 1 RAM base + 1 |
| `ov12_lo` / `ov12_hi` | overlay 12 base and base+size |
| `battle_state` | French value + the delta implied by `app_callback` |

The delta falls out of the main-loop literal for free (FR `0x021D112C`, US `0x021D110C`),
so five of six values are read straight from the ROM. Verified live over GDB: the config
block in a patched US ROM reads back exactly the resolved values, and `app_callback`
points into overlay 1's range as it should.

`battle_state` is the only value still *inferred* rather than read. If US battles
misbehave, re-derive it with `tools/savestate.py intersect` on US savestates — and
remember the rule that a candidate is not confirmed until probed live in a state outside
the sample.

## Screens that never write POWCNT1

Some apps route the wrong engine to the top and cannot be caught by static site flips.
Two mechanisms cover them:

- **Overworld X menu** — drawn *inside* the field app (callback stays `0x021E5921`), with
  no POWCNT1 write and no app transition. Nothing to detect, so it is driven from the
  buttons the player already presses: **X toggles, B restores**.
- **`app_table` in `src/hook.s`** — `{app callback, desired routing}` pairs applied on app
  transition. First entry: **name entry** (`0x02083141`, ARM9-resident) which sets the
  global flag at `0x021D1195` to 1 and calls the shared helper, putting its engine-A
  keyboard on the bottom. Add entries here as more screens turn up.

## Automatic battle swapping: what was missing (historical)

Needs a battle sub-state variable (action-select vs turn resolution). Blockers hit:

- The **melonDS GDB stub accepts exactly one connection per emulator launch** — verified
  twice, reconnection always fails with `vMustReplyEmpty: timeout`. So each run yields a
  single memory snapshot.
- The battle context pointer (`[0x021D1130]`) **moves between runs** (`0x022C0294` vs
  `0x022C026C`), so a raw fixed-address diff across two launches is unreliable.

Cleanest way forward: two **melonDS savestates** on the same build (one at action-select,
one during resolution). Savestates contain full main RAM, so both states can be diffed
offline with no emulator driving and no pointer drift.

## Open problem (historical): battles

Battles load overlays 6, 7, 10, 12, 18; **overlay 10 is reloaded every time the player
picks an action**, so it is the action-select menu. **Overlay 10 contains no POWCNT1 site
at all** — it inherits whatever routing the battle set up (ov12, site `0x02239B6E`).

So a static flip of ov12 would put the command menu on top for the *entire* battle,
including animations. Battles therefore still need **dynamic** swapping between
action-select and turn resolution. Everything else (menus, bag, party, PC, shops) is
solvable with static flips alone.

## Free space: SOLVED — ~31 KB of unused ITCM

The ARM9 autoload list at `0x02111F00` has exactly two blocks:

| block | destination | image size | bss |
|---|---|---|---|
| 1 | `0x01FF8000` — **ITCM** | `0x620` | 0 |
| 2 | `0x027E0000` — DTCM | `0x60` | `0x20` |

ITCM is 32 KB (`0x01FF8000`–`0x02000000`) and HGSS uses **1568 bytes of it**. That leaves
**`0x01FF8620`–`0x02000000`, about 31 KB**, which is:

- always resident (never paged, never unloaded),
- outside the BSS clear range, so nothing wipes it,
- the fastest memory on the ARM9,
- reachable by Thumb `BL` from ARM9 (~173 KB away) and from every overlay (~2.5 MB), both
  well inside the ±4 MB branch range.

Claim it by appending a **third autoload entry**: put the code image after the existing
autoload images (file offset `0x111F00`), move the autoload list after it, and update
`autoload_list` / `autoload_list_end` in MODULE_PARAMS. This is safe because the existing
ITCM/DTCM images already live at `autoload_start == static_bss_start`, which proves
autoload processing runs *before* the BSS clear.

**Implemented and verified end-to-end** (`onescreen/inject.py`, `src/hook.s`,
`build.py --inject`). Built `out/ipgf-v4.nds`, booted it, and read ITCM over GDB:

```
0x1ff8620:  0x53475331  0x00000001  0x88114a09  0x28000ad3
            "1SGS"      version     ldr/ldrh    lsrs/cmp
```

Byte-for-byte the assembled payload, resident from boot, game runs normally.
52 bytes used, **31,148 bytes of ITCM still free**. Exported entry points:

| symbol | address |
|---|---|
| `OneScreen_Signature` | `0x01FF8620` |
| `OneScreen_SetSwap(r0)` | `0x01FF8628` — r0=0 engine A top, r0!=0 UI on top |
| `OneScreen_GetSwap()` | `0x01FF863C` |

## Debugging: melonDS GDB stub

`[Instance0.Gdb] Enabled = true`, ARM9 on port 3333 (JIT already off by default). Attach
with the devkitARM gdb — `tools/probe.ps1` wraps it. **The stub accepts only one
connection per emulator launch**, so it is one probe per run; drive the game to the state
you want, then probe once.

Measured ground truth (v3):

| state | app callback `[0x021D112C]` | flag `[0x021D1195]` | live POWCNT1 |
|---|---|---|---|
| overworld | `0x021E5921` (ov001 base = field) | 0 | `0x820F` (bit15 **set**, engine A top) |
| party screen | `0x020796B9` (**ARM9 static**) | 0 | `0x020F` (bit15 clear, engine A bottom) |

The party being an ARM9-resident app with its own CLR-family site at `0x02078E66` is what
made it look like it "inherited" routing. It does not.

## Analyser bug worth remembering

`_analyse` originally treated **any** `STRH` as the commit point. The compiler interleaves
unrelated stores into these sequences — e.g. at `0x02078E66`:

```
ldr  r2, =POWCNT1
strh r1, [r3, #0]     <- unrelated store, NOT the commit
ldrh r1, [r2, #0]
ldr  r0, =0xFFFF7FFF
ands r0, r1
strh r0, [r2, #0]     <- the real commit
```

Only a store through the POWCNT1 register ends the sequence; anything else must be skipped.
Fixing this took the site count from 82 to **87 (45 CLR + 42 SET)** and is what made the
party screen fixable.

## Per-site intents

`0x02022D3E` must never be flipped: it is inside the shared helper, so flipping it inverts
every app that uses the helper *including the field*. `0x0201A2A2` (boot init) likewise.
Everything else defaults to FLIP. See `SITE_INTENT` in `onescreen/table.py`.

## Dead ends (recorded so they aren't retried)

- **ARM9 zero-run "free space"** (3602 bytes across 26 regions, identical addresses in
  both games): all of it is inside live data tables indexed by base+offset — the
  surrounding bytes are structured arrays and pointer tables. Not safe.
- **"Dead function" detection by unreferenced Thumb `push {..,lr}` prologue**: produces
  false positives inside ARM-mode regions (e.g. `0x020CBCEC` is mid-`memcpy`, not a
  function). Would need real ARM/Thumb region separation to be trustworthy.
- Neither matters now — the flip approach needs no free space.

## Tooling notes

- `ndspy` handles BLZ decompress/recompress; a load→save round-trip differs from the
  original in only 11 bytes (ROM-size field, header CRC, trailing padding).
- Patched ARM9 and overlays are stored **uncompressed** (`compressed_static_end = 0`,
  overlay compression flag cleared). Costs ~200 KB of the ~7.5 MB free ROM space and
  avoids BLZ recompression risk entirely. Verified to boot.
- melonDS 1.1 ships with **all keys unbound**; `tools/melonds_config.py` sets them
  (Qt key codes) and switches `ScreenSizing` (4 = top only).
- Screenshots via `PrintWindow` with `PW_RENDERFULLCONTENT` work without stealing focus.
  Note the ALT tap used to unlock `SetForegroundWindow` opens melonDS's Qt menu bar —
  send `ESC` afterwards or keystrokes hit the menu instead of the game.
