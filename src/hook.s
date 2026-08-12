@ 1ScreenHGSS - resident hook code, injected into unused ITCM.
@
@ HGSS's ARM9 autoload list puts only 0x620 bytes into ITCM (32 KB at
@ 0x01FF8000), leaving ~31 KB free. We claim it with a third autoload entry, so
@ this code is resident from boot, never unloaded, and never touched by the BSS
@ clear. Thumb BL reaches it from ARM9 and from every overlay.

    .cpu    arm946e-s
    .syntax unified
    .thumb
    .section .text
    .align  2

POWCNT1     = 0x04000304
SWAP_BIT    = 0x8000            @ bit 15: 1 = engine A -> top LCD

@ --- Region-resolved addresses ---------------------------------------------
@ ARM9 *code* addresses are identical across HGSS regions - verified by finding
@ the same anchors at the same addresses in French and US HeartGold. Only data,
@ BSS and overlay bases move, uniformly (US = FR - 0x20).
@
@ So rather than ship one payload per region, the six address-valued constants
@ live in OneScreen_Config below, which the patcher fills in from the ROM it is
@ patching. The DEF_ values are the French ones, so an unconfigured payload is
@ still correct for French.
@ The "state block" is pret's `struct System gSystem` (include/system.h), at
@ 0x021D112C in the French ROMs. Every address below is a field of it, and the
@ layout cross-checks perfectly against what was measured empirically:
@     +0x00  GFIntrCB vBlankIntr    each app installs its own, so it identifies
@                                   the running app - what we call app_callback
@     +0x38  int heldKeysRaw        the pad, before button-mode remapping
@     +0x44  int newKeys            (unused here; we derive edges ourselves)
@     +0x69  u8  screensFlipped     the game's OWN routing flag - see the note
@                                   at the top of OneScreen_SetSwap
DEF_PAD_HELD       = 0x021D1164 @ gSystem.heldKeysRaw
DEF_APP_CALLBACK   = 0x021D112C @ gSystem.vBlankIntr
DEF_FIELD_CALLBACK = 0x021E5921 @ overlay 1 base + 1 (Thumb)
DEF_OV12_LO        = 0x022378E0 @ overlay 12 (battle system) RAM range
DEF_OV12_HI        = 0x0226EC60
DEF_BATTLE_STATE   = 0x021D0E28 @ see the note below
DEF_DEX_EXEC_ORIG  = 0x021E5B81 @ the Pokedex app's real exec function
DEF_PC_EXEC_ORIG   = 0x021E598D @ the PC box app's real exec function
DEF_FIELD_SYS      = 0x021D4178 @ sFieldSysPtr - see OneScreen_ScriptMenu
DEF_SCREENS_FLIP   = 0x021D1195 @ gSystem.screensFlipped (gSystem + 0x69)
DEF_MAP_EXEC_ORIG  = 0x021ED8D5 @ the fly / town map app's real exec function
DEF_START_MENU_TASK = 0x0203BEF1 @ Task_StartMenu; 0 if the patcher cannot vouch
DEF_OAK_EXEC_ORIG  = 0x021E59B5 @ Oak's speech (overlay 53) real exec function

KEY_A       = 0x001
KEY_B       = 0x002
KEY_R       = 0x100
KEY_L       = 0x200
KEY_X       = 0x400
DPAD_MASK   = 0x0F0             @ right | left | up | down
TOGGLE_MASK = (KEY_L | KEY_R)   @ L+R together; unused by HGSS gameplay

@ The field callback is overlay 1's first function (+1 for Thumb). Measured
@ identical in the plain overworld and with the X menu open - the menu is drawn
@ *inside* the field app, so there is no app transition to hook and no POWCNT1
@ write of its own.
@
@ Battle phase. The game has no "is the player choosing?" flag, so this reads a
@ proxy, found empirically by savestate intersection and only later identified
@ with the decomp. It is pret's poke_overlay.c:
@
@     typedef struct PMiLoadedOverlay { FSOverlayID id; BOOL active; };
@     static PMiLoadedOverlay sOverlayRegions[OVY_REGION_NUM][OVY_MAX_PER_REGION];
@
@ and specifically main-region slot 3's overlay id. The battle loads a different
@ overlay for each phase, so that one word tracks the phase:
@     0x0A  overlay 10 - the command menu / move list
@     0x08  overlay 8  - a sub-screen (bag category, item list, party)
@     0x07  overlay 7  - the turn is executing
@     0x1B  a stale id left over from before the battle; the slot is inactive
@ Testing NEGATIVELY - awaiting a command unless it reads 0x07 - covers every
@ waiting sub-state including ones we never enumerated, and it flips the instant
@ the turn machinery loads overlay 7, so the swap is not late.
@
@ Rejected on the way: 0x02111930 reads 0x06 both when a command has been
@ confirmed AND while a sub-screen is up, so it threw the scene back on top the
@ moment you went a level deeper into the bag. 0x021E17C4 and 0x02134F15 lag -
@ they only change once the turn is already under way, which looks late.
@
@ The caveat that matters: this says which overlay is RESIDENT, not whether the
@ menu is accepting input. Overlay 10 is already loaded while the battle intro
@ text is still playing, so "awaiting a command" goes true early. See the A
@ handling in OneScreen_AutoBattle, which is what stops that mattering.
BATTLE_STATE_EXEC = 0x07
BATTLE_STATE_SUB  = 0x08        @ bag category, item list, party

@ Frames of no input before the command menu drops back to the battle scene.
IDLE_FRAMES = 60                @ ~1 s at 60 fps

@ The main-loop call we displace: `bl 0x0200110C` at 0x02000DB0.
ORIG_LOOP_FN = 0x0200110C + 1   @ +1 = Thumb

@ Pokedex area map. The species grid and the per-Pokemon detail level share one
@ app callback and the same POWCNT1 value, so neither app_table nor a scan for a
@ sub-state byte could separate them - two candidates were tried from savestate
@ diffs and both turned out to be noise.
@
@ pret/pokeheartgold settled it. The Pokedex is an OverlayManager application:
@
@     struct OverlayManager { OverlayManagerTemplate template;  // init/exec/exit/ovy_id
@                             int exec_state;                   // +0x10
@                             int proc_state;                   // +0x14
@                             void *args; void *data; ... };
@
@ and the framework calls template.exec(manager, &manager->proc_state) every
@ frame. So instead of hunting for the state in RAM, we take over that exec
@ pointer: r1 arrives holding &proc_state, which IS the screen level. Measured
@ across four savestates covering two different Pokemon:
@     11  species grid
@     69  detail level, where the area map is on engine B (the bottom screen)
@ 69 also has its own struct in the decomp (PokedexAppData_UnkSub0868_State69),
@ which corroborates it being a real distinct screen.
@
@ Swapping on 69 alone made the map fade in on the BOTTOM screen and then jump
@ across once it was fully visible. The decomp shows why: 69 is not where the map
@ is built. PokedexApp_MainSeq_68 builds it, starts a fade in from black, and
@ hands off to MainSeq_03 - the shared "wait for the palette fade" state, which
@ returns to whatever unk_085C names. Only when the fade has finished does 68
@ return 69. So the whole visible fade-in happens under states 68 and 03.
@
@ Two consequences for the rule below:
@   * the map screen is a RANGE of states, not just 69. 69 is the idle screen,
@     70 fades back out, and 71..75 handle scrolling between maps and the
@     sub-interactions - all of them return to 69.
@   * states 02 and 03 are the shared fade waits, entered from BOTH sides, so
@     they say nothing about which screen we are on and must not be treated as
@     "not the map". They hold the current routing instead.
@
@ Acting during the build also makes the swap invisible: the map fades in FROM
@ black, so the previous screen has already faded out and both engines are black
@ at the moment we flip. Same reason the menus never flashed.
@
@ Which state does the building depends on how you got there, and this is what a
@ first attempt at 68 alone still flashed on:
@
@     from another tab   91 (or 78 / 81) fades out -> 03 -> returns 68
@     from the species grid              64 / 15   -> 03 -> returns 66
@
@ and MainSeq_66 sets up and then **tail-calls PokedexApp_MainSeq_68 directly**:
@
@     static int PokedexApp_MainSeq_66(PokedexAppData *app) {
@         ...
@         return PokedexApp_MainSeq_68(app);
@     }
@
@ so on that path the map is built and the fade started while proc_state still
@ reads 66, and the value 68 is never seen until the fade has already finished.
@ Hence the range starts at 66. Both routes into 66 come after a fade to black
@ (one of them also calls ZeroPalettesByBitmask), so swapping there is invisible.
@
@ 67 is the shared "fade this tab out and go back to the list" state, reached
@ from whichever tab was open, so like 02/03 it must hold rather than pick a
@ side - otherwise leaving the map threw it to the bottom before it faded.
DEX_MAP_LO  = 66
DEX_MAP_HI  = 75
DEX_FADE_LO = 2                 @ MainSeq_02 / MainSeq_03: wait for a fade
DEX_FADE_HI = 3
DEX_TAB_FADE = 67               @ MainSeq_67: fade the open tab out

NO_STATE = 0xFF                 @ "not in a battle" sentinel

@ Frames the PC box routing is held after each call into the app. Two is enough
@ to cover the main loop running our hook before the app's exec rather than
@ after, without outliving the app by anything a player could see.
PC_HOLD_FRAMES = 2

@ Flying. Selecting a destination on the Town Map used to leave the whole flight
@ animation on the bottom screen, and it only came back after the player walked
@ around at the far end. Savestates through the sequence show why:
@
@     before pressing A   Town Map app live, overlay 101, exec_state 2
@     just after A        same manager, exec_state 3 - the app is EXITING
@     mid-animation       app gone; gSystem.vBlankIntr is the field again
@     arrived / fixed     identical field state in both - only POWCNT1 differs
@
@ So the flight animation is drawn by the FIELD, after the Town Map app tears
@ down, and nothing restores the field's own routing when that happens: the
@ Town Map's layout is simply left in place. Nothing in FieldSystem distinguishes
@ "arrived but wrong" from "arrived and correct" - the two savestates match
@ field for field - which is the proof that no state flag can drive this. It has
@ to be the app transition.
@
@ So when an application hands the field back, put the world on top for a few
@ frames. Gated behind the X-menu latch and the script-menu check, so coming back
@ from the bag into an open menu, or into a shop list, is unaffected.
@
@ That gate was also why a first attempt at this changed nothing. Reading the
@ hook's own variables back out of the savestates - the payload signature "1SGS"
@ makes them easy to find in ITCM - showed menu_swapped stuck at 1 for the whole
@ flight and only 0 once it had corrected itself. Flying is reached THROUGH the X
@ menu, and the latch is deliberately kept across sub-apps so that a trip into
@ the bag and back leaves the menu on top. But flying does not come back to the
@ menu, it comes back to the world, so the latch has to be dropped - and Poll was
@ re-applying "menu on top" every frame, which is what put the flight animation
@ on the bottom screen in the first place.
FIELD_RESTORE_FRAMES = 30

@ Frames the fly map's exit is waited for. Two is enough to notice the app has
@ stopped calling the trampoline.
MAP_LAPSE_FRAMES = 2

@ ...and then how long to wait for the FIELD to pick up. This is the part a
@ first attempt got wrong: it tested "is the field running?" once, on the frame
@ the app lapsed, and gave up for good if not. But gSystem.vBlankIntr reads 0
@ for a stretch right after the town map tears down - the savestate taken just
@ after confirming a destination shows exactly that - so the single test always
@ landed in the gap and never fired. Wait for the field instead, and cancel if
@ some other application takes over rather than the field.
MAP_PENDING_FRAMES = 180        @ ~3 s, far longer than the handover needs

@ FieldSystem.taskman - the field's running task, see OneScreen_MenuGone.
TASKMAN_OFF = 0x10
TASK_FUNC_OFF = 0x04
TASK_ENV_OFF = 0x0C

@ StartMenuTaskData.state (include/start_menu.h), the menu's own state machine.
@ Its exit path is what shows the menu for a moment after choosing Dig or an
@ Escape Rope: 12 pauses the map and starts a fade, 13 waits for the fade then
@ jumps to the exit task and frees the menu. Measured across the flash -
@
@     just before, on black   func Task_StartMenu, state 12
@     during the flash        func Task_StartMenu, state 13
@     after                   an overlay script task
@
@ - against state 3 (HANDLE_INPUT) for a menu that is genuinely up and taking
@ input. So the menu really is running during the flash, with the same task and
@ the same env; only this field separates "up" from "on its way out".
STARTMENU_STATE_OFF = 0x26
STARTMENU_EXIT_LO = 12          @ START_MENU_STATE_12: fade out
STARTMENU_EXIT_HI = 13          @ START_MENU_STATE_13: jump to the exit task

@ Oak's speech, overlay 53. One of the applications that sets POWCNT1 nowhere at
@ all, so it simply inherits whatever routing it starts with - which left the
@ whole opening monologue inverted: the "TOUCHER" prompt on top and Oak's text
@ on the bottom, where a top-only setup cannot see it.
@
@ Its OverlayManager proc_state only counts 0..5; the real screen is
@ OakSpeechData.state (include/oaks_speech_internal.h), reached through
@ manager->data. The enum is fully named in the decomp, so the boundaries need
@ no guessing:
@
@     ...60  TELL_ME_ABOUT_YOURSELF        Oak and the text  -> engine A on top
@     61     ARE_YOU_A_GENDER              still Oak talking
@     62     WAIT_FADE_OUT_TO_ASK_GENDER   the fade INTO the picker
@     63-65  SETUP / WAIT_FADE_IN / HANDLE_INPUT of the gender menu
@     66-72  ASK_CONFIRM_GENDER and its yes/no
@     93     CONFIRM_GENDER_YES
@     94+    PROMPT_NAME...                 back to Oak, then the naming screen,
@                                           which app_table already handles
@
@ Swapping over 62..93 puts the boy/girl cards up while leaving the speech
@ itself alone, and starting at 62 rather than 63 means the flip happens during
@ the game's own fade-out - the same rule the Pokedex map needed.
@ The opening tutorial menu - INFOS COMMANDES / INFOS AVENTURE / NON MERCI -
@ needs the same treatment, and the window templates say so outright:
@
@     sMultichoiceMenuButtonWindowTemplates[][].bgId = GF_BG_LYR_SUB_0
@     sFullScreenMsgWindowTemplate.bgId             = GF_BG_LYR_MAIN_0
@
@ The three buttons are on engine B, and the INFOS pages they lead to are on
@ engine A. So the menu swaps and the pages do not, which is exactly the split
@ that was wanted. States 0..7 cover it: 1..3 raise and run the menu, 4..6 fade
@ it out into a topic, and 7 fades it back in when the topic returns.
OAK_STATE_OFF = 0x0C            @ OakSpeechData.state
OAK_DATA_OFF = 0x08             @ manager->data, from &proc_state (+0x14)
OAK_TUTORIAL_HI = 7             @ 0..7: the tutorial menu
OAK_GENDER_LO = 62
OAK_GENDER_HI = 93

@ Field script menus - the PC option list, shop lists, NPC yes/no choices. All
@ of these are drawn on the touch screen by the running script, inside the field
@ app, so there is no app transition to detect and no POWCNT1 write of our own
@ to catch. The signal is in pret's FieldSystem (include/field_system.h):
@
@     struct FieldSystem { FieldProcessManager *processManager;  // +0x00
@                          ... ; int bottomScreenType;           // +0x18
@                          int unk1C; ... };                     // +0x1C
@
@ ScrCmd_TouchscreenMenuHide sets unk1C = 3 when a script takes the bottom
@ screen; ScrCmd_TouchscreenMenuShow sets it back to 0 for the normal icon bar.
@ Read through sFieldSysPtr, the file-static in field_system.c.
@
@ Confirmed on both sides, which is the rule that caught every bad candidate
@ before this: 3 in all seven PC savestates, and 0 in six out-of-sample states
@ from different sessions AND different builds (Pokedex, battle, overworld, name
@ entry). Exactly one stable ARM9-BSS pointer in the whole image fits, and the
@ struct it points at is unmistakable - six heap pointers, then these two ints.
@
@ Tested non-zero rather than == 3: any non-default mode means a script has put
@ something on the bottom screen that the player needs to see.
FIELD_MENU_OFF = 0x1C


@ --------------------------------------------------------------------------
@ Data. ITCM is RAM, so all of this is writable at runtime.
@ --------------------------------------------------------------------------
    .global OneScreen_Signature
OneScreen_Signature:
    .ascii  "1SGS"
    .word   0x00000016          @ payload version

@ Filled in by the patcher from the ROM being patched. Defaults are French, so
@ an unconfigured payload still works there. Keep the field order in step with
@ CONFIG_FIELDS in onescreen/inject.py.
    .global OneScreen_Config
OneScreen_Config:
cfg_pad_held:       .word DEF_PAD_HELD
cfg_app_callback:   .word DEF_APP_CALLBACK
cfg_field_callback: .word DEF_FIELD_CALLBACK
cfg_ov12_lo:        .word DEF_OV12_LO
cfg_ov12_hi:        .word DEF_OV12_HI
cfg_battle_state:   .word DEF_BATTLE_STATE
cfg_dex_exec_orig:  .word DEF_DEX_EXEC_ORIG
cfg_pc_exec_orig:   .word DEF_PC_EXEC_ORIG
cfg_field_sys:      .word DEF_FIELD_SYS
cfg_screens_flip:   .word DEF_SCREENS_FLIP
cfg_map_exec_orig:  .word DEF_MAP_EXEC_ORIG
cfg_start_menu_task: .word DEF_START_MENU_TASK
cfg_oak_exec_orig:  .word DEF_OAK_EXEC_ORIG

pad_held:       .word 0
pad_new:        .word 0         @ newly pressed this frame
prev_pad:       .word 0

menu_swapped:   .word 0         @ 1 while WE swapped for the overworld X menu
last_app:       .word 0

bt_phase:       .word NO_STATE  @ last battle phase acted on
bt_menu_up:     .word 0         @ 1 while the command menu is on the top screen
bt_committed:   .word 0         @ 1 once A was pressed: stop the idle timeout
bt_idle:        .word 0         @ frames since the last input
dex_last:       .word -1        @ last Pokedex proc_state acted on
dex_mode:       .word 0         @ 0 = grid/info side, 1 = the area map
pc_frames:      .word 0         @ frames left to hold the PC box routing
script_menu:    .word 0         @ 1 while WE swapped for a field script menu
field_restore:  .word 0         @ frames left to force the world back on top
map_frames:     .word 0         @ counts down once the fly map stops running
map_pending:    .word 0         @ frames left waiting for the field to pick up
prev_task:      .word 0         @ last frame's fieldSystem->taskman

@ Apps that route the wrong engine to the top and never write POWCNT1 in a way
@ our static site flips can catch. Pairs of {callback, swap}, terminated by 0.
@   swap 0 = engine A to the top   (use when the app draws its UI on engine A)
@   swap 1 = engine B to the top   (use when its UI is on engine B)
@
@ The patcher fills the callback addresses in, after checking that the code at
@ each one still matches the routine we expect - see regions.check_app_table. An
@ entry it cannot vouch for is zeroed, which ends the table early and simply
@ leaves that app alone rather than swapping on a wrong address. The values
@ assembled here are the French ones, so an unconfigured payload still works.
    .global OneScreen_AppTable
OneScreen_AppTable:
app_table:
    @ Name entry (rival/player/Pokémon nicknames). Not an OverlayManager app -
    @ this is the small ARM9 routine that sets the global flag at 0x021D1195 and
    @ calls the shared display helper, which puts its keyboard (drawn on engine
    @ A) on the bottom screen. Measured byte-identical in IPGF, IPKF and IPKE.
    .word   0x02083141, 0

    @ The evolution scene, and the move it teaches afterwards. Not an
    @ OverlayManager application and not part of the battle - it is ARM9 code
    @ driven from wherever the evolution was triggered, and it sets POWCNT1
    @ nowhere, so it simply keeps whatever routing it inherits. Coming from the
    @ bag that is the menu's, which put the narration on the bottom screen. It
    @ draws its Pokemon and text on engine A, so 0.
    .word   0x02077271, 0

    .word   0, 0


@ ---------------------------------------------------------------------------
@ void OneScreen_SetSwap(int swapped)
@   r0 == 0 -> engine A to the TOP screen
@   r0 != 0 -> engine A to the BOTTOM, engine B to the top
@
@ Note what this does NOT mean. It is tempting to read r0 = 1 as "bring the touch
@ UI up", and that is true for most apps only because they happen to draw their
@ touch UI on engine B. The PC box is the counter-example: stock HGSS runs
@ `POWCNT1 &= ~0x8000` there, putting engine B on TOP, which means its box grid
@ is on engine A. Passing 1 for the PC shoved the grid back down and undid the
@ static flip that had already put it on top. Always establish which engine an
@ app actually draws on before choosing a value.
@
@ This writes POWCNT1 directly, which is why callers have to re-apply it every
@ frame while a menu is up. The game routes screens through
@
@     void GfGfx_SwapDisplay(void) {          // src/gf_gfx_planes.c
@         if (gSystem.screensFlipped == 0) GX_SetDispSelect(GX_DISP_SELECT_MAIN_SUB);
@         else                             GX_SetDispSelect(GX_DISP_SELECT_SUB_MAIN);
@     }
@
@ so any app that calls it stamps its own idea of the routing back over ours -
@ exactly the "sub-screens re-assert the routing" behaviour worked around below.
@ Setting gSystem.screensFlipped (+0x69) instead would be the game-native way to
@ do this and would not need re-applying. Not changed here because the current
@ approach is tested and shipping; see docs/AUDIT.md before reworking it.
@ ---------------------------------------------------------------------------
    .global OneScreen_SetSwap
    .thumb_func
OneScreen_SetSwap:
    ldr     r2, =POWCNT1
    ldrh    r1, [r2]
    lsrs    r3, r2, #11             @ 0x04000304 >> 11 == 0x8000
    cmp     r0, #0
    beq     1f
    bics    r1, r3                  @ clear bit 15 -> UI on top
    b       2f
1:  orrs    r1, r3                  @ set bit 15 -> engine A on top
2:  strh    r1, [r2]
    bx      lr
    .align  2
    .pool

@ ---------------------------------------------------------------------------
@ void OneScreen_Toggle(void)
@ ---------------------------------------------------------------------------
    .global OneScreen_Toggle
    .thumb_func
OneScreen_Toggle:
    ldr     r2, =POWCNT1
    ldrh    r1, [r2]
    lsrs    r0, r2, #11
    eors    r1, r0
    strh    r1, [r2]
    bx      lr
    .align  2
    .pool

@ ---------------------------------------------------------------------------
@ void OneScreen_UpdatePad(void)
@ Sample the pad once per frame and derive the newly-pressed edges, so every
@ other routine works from the same snapshot.
@ ---------------------------------------------------------------------------
    .global OneScreen_UpdatePad
    .thumb_func
OneScreen_UpdatePad:
    ldr     r0, =cfg_pad_held
    ldr     r0, [r0]
    ldr     r0, [r0]
    ldr     r1, =prev_pad
    ldr     r2, [r1]
    str     r0, [r1]
    mvns    r2, r2
    ands    r2, r0                  @ newly pressed = held & ~prev
    ldr     r1, =pad_held
    str     r0, [r1]
    ldr     r1, =pad_new
    str     r2, [r1]
    bx      lr
    .align  2
    .pool

@ ---------------------------------------------------------------------------
@ void OneScreen_AutoBattle(void)
@
@ The command menu is NOT forced up the moment the game asks for an action -
@ that would hide the battle scene exactly when you want to read the result of
@ the last turn. Instead it comes up when you actually start choosing, and
@ steps aside again if you stop.
@
@   turn executing        -> battle scene on top
@   awaiting a command    -> leave the scene up until you touch the D-pad or A
@   D-pad or A pressed    -> command menu on top
@   ~2 s with no input    -> back to the scene
@   A pressed (selection) -> stays up; the timeout is cancelled, so the move
@                            list does not disappear while you read it
@
@ A counts as a trigger because the cursor starts on ATTAQUE: pressing A without
@ moving first would otherwise open the move list unseen on the bottom screen.
@
@ Gated on the running app living inside overlay 12, so none of this can affect
@ the overworld or any menu - those are handled by the static site flips.
@ ---------------------------------------------------------------------------
    .global OneScreen_AutoBattle
    .thumb_func
OneScreen_AutoBattle:
    push    {r4, r5, lr}
    ldr     r4, =bt_phase

    ldr     r0, =cfg_app_callback
    ldr     r0, [r0]
    ldr     r0, [r0]
    ldr     r1, =cfg_ov12_lo
    ldr     r1, [r1]
    cmp     r0, r1
    blo     29f
    ldr     r1, =cfg_ov12_hi
    ldr     r1, [r1]
    cmp     r0, r1
    bhs     29f

    @ Collapse the raw state to a single bit first. It takes several values while
    @ awaiting a command (0x0A menu, 0x08 sub-screen), and treating each of those
    @ as a transition would reset the interaction state - dropping the menu as
    @ soon as you opened the bag.
    @ The slot's `active` flag, not just its id. Battle_Run keeps running after
    @ the fight is over - BSTATE_EVOLUTION_INIT and friends are part of the same
    @ application - so the battle logic was still live during an evolution and
    @ the move it teaches. Mashing A through that text raised the command menu,
    @ which put the narration on the bottom screen.
    @
    @ A stale id in a released slot reads the same as a live one, so the id alone
    @ cannot tell the difference; `active` can. Measured 1 in three mid-battle
    @ savestates, so requiring it cannot stop a real battle from swapping.
    ldr     r0, =cfg_battle_state
    ldr     r0, [r0]
    ldr     r1, [r0, #4]            @ sOverlayRegions[OVY_REGION_MAIN][3].active
    cmp     r1, #0
    beq     29f                     @ released: the battle proper has ended
    ldrb    r0, [r0]
    movs    r5, #0
    cmp     r0, #BATTLE_STATE_EXEC
    bne     20f
    movs    r5, #1                  @ executing
20: ldr     r1, [r4]
    cmp     r5, r1
    beq     21f                     @ same phase as last frame

    @ --- phase changed: reset the interaction state ---
    str     r5, [r4]
    bl      OneScreen_ResetBattleUi
    cmp     r5, #0
    beq     28f                     @ entering "awaiting command": do NOT swap
    movs    r0, #0                  @ turn executing -> battle scene on top
    bl      OneScreen_SetSwap
    b       28f

21: cmp     r5, #0
    bne     28f                     @ mid-turn: nothing to do

    ldr     r5, =pad_new
    ldr     r5, [r5]

    @ any input at all re-arms the idle timeout
    cmp     r5, #0
    beq     24f
    ldr     r0, =bt_idle
    movs    r1, #0
    str     r1, [r0]

    @ B backs out of a submenu (move list, bag, party) to the root command menu.
    @ Drop the commit so the idle timeout re-arms - otherwise the menu stays up
    @ forever once you have been into a submenu and come back.
    movs    r0, r5
    movs    r1, #KEY_B
    ands    r0, r1
    cmp     r0, #0
    beq     23f
    ldr     r0, =bt_committed
    movs    r1, #0
    str     r1, [r0]
    b       26f

    @ A = a selection: bring the menu up and keep it there. Do NOT try to guess
    @ which A press confirms the command - the count varies (the move list needs
    @ a different number of presses depending on whether you moved the cursor
    @ first, backed out with B, or picked SAC/POKéMON). The state variable above
    @ flips on confirmation anyway, so let it do the work.
    @
    @ A only counts as a selection if there was a menu on screen to select FROM.
    @ The phase reads "awaiting a command" from the moment overlay 10 loads,
    @ which is while the battle intro text is still playing - so mashing A to
    @ skip that text used to land here, set the commit, and pin the menu on the
    @ top screen for the rest of the fight with no way back but a trip into a
    @ submenu. An A press with no menu up just brings it up, like the D-pad.
23: movs    r0, r5
    movs    r1, #KEY_A
    ands    r0, r1
    cmp     r0, #0
    beq     22f
    ldr     r0, =bt_menu_up
    ldr     r0, [r0]
    cmp     r0, #0
    beq     25f
    ldr     r0, =bt_committed
    movs    r1, #1
    str     r1, [r0]
25: bl      OneScreen_ShowMenu
    b       26f

    @ D-pad = started navigating: bring the menu up
22: movs    r0, r5
    ldr     r1, =DPAD_MASK
    ands    r0, r1
    cmp     r0, #0
    beq     26f
    bl      OneScreen_ShowMenu
    b       26f

    @ --- no input this frame: run the idle timeout ---
24: ldr     r0, =bt_menu_up
    ldr     r0, [r0]
    cmp     r0, #0
    beq     28f                     @ menu is not up; nothing to time out
    ldr     r0, =bt_committed
    ldr     r0, [r0]
    cmp     r0, #0
    bne     26f                     @ a selection was made: leave it up
    @ A sub-screen is open - you are browsing the bag or the party, where long
    @ pauses are normal. Hold regardless of what we think you selected; this is
    @ the game's own state, so it is right even if the commit above is not.
    ldr     r0, =cfg_battle_state
    ldr     r0, [r0]
    ldrb    r0, [r0]
    cmp     r0, #BATTLE_STATE_SUB
    beq     26f
    ldr     r1, =bt_idle
    ldr     r0, [r1]
    adds    r0, #1
    str     r0, [r1]
    cmp     r0, #IDLE_FRAMES
    blo     26f
    ldr     r0, =bt_menu_up
    movs    r1, #0
    str     r1, [r0]
    movs    r0, #0                  @ idle too long -> back to the scene
    bl      OneScreen_SetSwap
    b       28f

    @ --- hold the routing while the player is navigating ---
    @ Sub-screens opened from the battle menu (item categories, the item list,
    @ the party list) re-assert the display routing themselves as they open, so a
    @ one-shot swap gets undone the moment you go a level deeper. Re-apply it
    @ every frame while the menu is up. L+R clears bt_menu_up, so a manual
    @ override still wins and is not fought.
26: ldr     r0, =bt_menu_up
    ldr     r0, [r0]
    cmp     r0, #0
    beq     28f
    movs    r0, #1
    bl      OneScreen_SetSwap
    b       28f

29: movs    r0, #NO_STATE           @ not in a battle: re-arm for next time
    str     r0, [r4]
    bl      OneScreen_ResetBattleUi
28: pop     {r4, r5, pc}
    .align  2
    .pool

@ void OneScreen_ShowMenu(void) - put the command menu up, once.
    .thumb_func
OneScreen_ShowMenu:
    push    {lr}
    ldr     r0, =bt_menu_up
    ldr     r1, [r0]
    cmp     r1, #0
    bne     31f                     @ already up
    movs    r1, #1
    str     r1, [r0]
    movs    r0, #1
    bl      OneScreen_SetSwap
31: pop     {pc}
    .align  2
    .pool

@ void OneScreen_ResetBattleUi(void)
    .thumb_func
OneScreen_ResetBattleUi:
    movs    r1, #0
    ldr     r0, =bt_menu_up
    str     r1, [r0]
    ldr     r0, =bt_committed
    str     r1, [r0]
    ldr     r0, =bt_idle
    str     r1, [r0]
    bx      lr
    .align  2
    .pool

@ ---------------------------------------------------------------------------
@ int OneScreen_DexExec(OverlayManager *manager, int *proc_state)
@
@ Installed in place of the Pokedex application's exec pointer, in the
@ OverlayManagerTemplate that lives in ARM9 static data. The framework hands us
@ r1 = &manager->proc_state, i.e. the current screen level, then we tail-call
@ the real exec so the app is unaffected.
@
@ Edge-triggered on the level changing, so a manual L+R is not fought while you
@ sit on a screen - but re-applied on every change, not only when the side
@ flips, because the app reconfigures the display as it builds each screen.
@ ---------------------------------------------------------------------------
    .global OneScreen_DexExec
    .thumb_func
OneScreen_DexExec:
    push    {r0, r1, lr}
    ldr     r2, [r1]                @ proc_state = the screen level
    ldr     r3, =dex_last
    ldr     r0, [r3]
    cmp     r0, r2
    beq     53f                     @ same level as last frame
    str     r2, [r3]

    @ A fade wait tells us nothing about which side we are on: hold.
    movs    r0, r2
    subs    r0, #DEX_FADE_LO
    cmp     r0, #(DEX_FADE_HI - DEX_FADE_LO)
    bls     52f
    cmp     r2, #DEX_TAB_FADE
    beq     52f

    movs    r0, r2
    subs    r0, #DEX_MAP_LO
    cmp     r0, #(DEX_MAP_HI - DEX_MAP_LO)
    bhi     50f
    movs    r0, #1                  @ the area map -> engine B on top
    b       51f
50: movs    r0, #0                  @ anything else -> engine A on top
51: ldr     r3, =dex_mode
    str     r0, [r3]

52: ldr     r3, =dex_mode
    ldr     r0, [r3]
    bl      OneScreen_SetSwap
53: pop     {r0, r1}
    pop     {r2}
    mov     lr, r2
    ldr     r3, =cfg_dex_exec_orig
    ldr     r3, [r3]
    bx      r3                      @ tail-call the app's real exec

    .align  2
    .pool

@ ---------------------------------------------------------------------------
@ int OneScreen_PcExec(OverlayManager *manager, int *proc_state)
@
@ The PC box (overlay 14), installed the same way as the Pokedex trampoline.
@
@ Overlay 14 is one of the 75 the decomp has not reached, so there is no state
@ machine to read - the screen levels came from savestates instead. Reading
@ proc_state out of the live manager at each of them:
@
@     inside a box, cursor on a Pokemon    81
@     inside a box, holding a Pokemon     115
@     item storage                        117
@     fading in / fading out                0   (exec_state 2 / 3)
@
@ and, the useful part, the PC option list ("DEPOT POKEMON" / "MON PC" / ...)
@ has NO overlay-14 manager at all - checked both before entering and after
@ backing out. That list is a field menu; the app only exists once you are
@ inside. So the whole of overlay 14 is "managing the box", and every screen in
@ it wants engine B on top. There is nothing to distinguish, and no per-state
@ rule to get wrong.
@
@ The direction here was wrong twice before it was measured properly. Overlay 14
@ has exactly one POWCNT1 site, and disassembling it in the stock ROM settles
@ which engine the box is on:
@
@     stock     ldr r0,=0xFFFF7FFF ; ands r0,r1 ; strh   ->  clears bit 15
@     patched   ldr r0,=0x00008000 ; orrs r0,r1 ; strh   ->  sets   bit 15
@
@ So stock HGSS puts engine B on the TOP screen for the PC, which means the box
@ grid - the half you actually operate - is drawn on engine A. The static site
@ flip already turns that into "engine A on top", i.e. the grid on top, and it
@ needs no help. Forcing r0 = 1 here, on the assumption that the touch UI must
@ be on engine B like everywhere else, pushed the grid straight back down and
@ undid the flip.
@
@ What remains is only insurance against something re-routing later in the
@ frame: run the app first, then re-assert the SAME direction the flipped site
@ already chose, and arm a countdown so OneScreen_Frame keeps doing it from
@ where the battle logic writes from. Everything now agrees - the flipped site,
@ GfGfx_SwapDisplay with screensFlipped = 0, and us.
@
@ Coming out is self-healing: the countdown lapses and the field re-asserts.
@ ---------------------------------------------------------------------------
    .global OneScreen_PcExec
    .thumb_func
OneScreen_PcExec:
    push    {r4, lr}
    ldr     r3, =cfg_pc_exec_orig
    ldr     r3, [r3]
    blx     r3                      @ let the app run and route as it likes
    movs    r4, r0                  @ keep its return value
    ldr     r0, =pc_frames
    movs    r1, #PC_HOLD_FRAMES
    str     r1, [r0]
    movs    r0, #0                  @ ...then hold engine A on top, which is
    bl      OneScreen_SetFlipped    @ where the box grid is drawn
    movs    r0, #0
    bl      OneScreen_SetSwap
    movs    r0, r4
    pop     {r4, pc}

    .align  2
    .pool

@ void OneScreen_PcHold(void) - re-apply the PC routing from the main loop, for
@ as long as the trampoline keeps re-arming it, and hand the screens back one
@ frame after the app stops calling us.
    .thumb_func
OneScreen_PcHold:
    push    {lr}
    ldr     r1, =pc_frames
    ldr     r0, [r1]
    cmp     r0, #0
    beq     41f
    subs    r0, #1
    str     r0, [r1]
    cmp     r0, #0
    beq     41f                     @ just lapsed: leave it to the field
    movs    r0, #0
    bl      OneScreen_SetFlipped
    movs    r0, #0
    bl      OneScreen_SetSwap
41: pop     {pc}
    .align  2
    .pool

@ ---------------------------------------------------------------------------
@ int OneScreen_MapExec(OverlayManager *manager, int *proc_state)
@
@ The fly / town map application, overlay 101. Hooked not for its own routing
@ but for the moment it STOPS running, which is the frame after you confirm a
@ destination - exactly where the swap was asked for.
@
@ Savestates through a flight show the app live with exec_state 2 before the
@ press, exec_state 3 immediately after, and gone by mid-animation with the field
@ running again. The animation is drawn by the FIELD, so there is no app of ours
@ left to hook by then; and the arrived-but-wrong and arrived-and-correct states
@ are identical field for field, differing only in POWCNT1, so no state flag can
@ drive it either. The app going away is the only edge available.
@ ---------------------------------------------------------------------------
    .global OneScreen_MapExec
    .thumb_func
OneScreen_MapExec:
    push    {r4, lr}
    ldr     r3, =cfg_map_exec_orig
    ldr     r3, [r3]
    blx     r3
    movs    r4, r0
    ldr     r0, =map_frames
    movs    r1, #MAP_LAPSE_FRAMES
    str     r1, [r0]
    movs    r0, r4
    pop     {r4, pc}
    .align  2
    .pool

@ void OneScreen_MapHold(void) - notice the fly map going away, then wait for
@ the field to pick up and hand it the screen.
    .thumb_func
OneScreen_MapHold:
    push    {lr}
    ldr     r1, =map_frames
    ldr     r0, [r1]
    cmp     r0, #0
    beq     46f
    subs    r0, #1
    str     r0, [r1]
    cmp     r0, #0
    bne     47f                     @ still running
    ldr     r1, =map_pending        @ it has gone: start waiting for the field
    movs    r0, #MAP_PENDING_FRAMES
    str     r0, [r1]
    b       47f

46: ldr     r1, =map_pending
    ldr     r0, [r1]
    cmp     r0, #0
    beq     47f
    subs    r0, #1
    str     r0, [r1]

    ldr     r0, =cfg_app_callback
    ldr     r0, [r0]
    ldr     r0, [r0]
    cmp     r0, #0
    beq     47f                     @ still handing over; keep waiting
    ldr     r2, =cfg_field_callback
    ldr     r2, [r2]
    cmp     r0, r2
    beq     48f
    movs    r0, #0                  @ some OTHER app took over - backing out of
    str     r0, [r1]                @ the town map into the Pokegear. Cancel.
    b       47f

48: movs    r0, #0                  @ the field has it: this was a flight, which
    str     r0, [r1]                @ returns to the world and not to the menu
    ldr     r1, =menu_swapped
    str     r0, [r1]
    ldr     r1, =field_restore
    movs    r0, #FIELD_RESTORE_FRAMES
    str     r0, [r1]
    movs    r0, #0
    bl      OneScreen_SetSwap       @ and put the world up right now
47: pop     {pc}
    .align  2
    .pool

@ ---------------------------------------------------------------------------
@ void OneScreen_SetFlipped(int value)
@ Write gSystem.screensFlipped, the game's OWN routing flag.
@
@ Writing POWCNT1 ourselves is not enough for every app. GfGfx_SwapDisplay reads
@ this byte and re-derives the routing from it, and it can be reached from a
@ VBlank callback - i.e. after everything the main loop does - so a direct
@ POWCNT1 write can be undone later in the same frame no matter where we put it.
@ Overlay 14 has only ONE POWCNT1 site of its own, and gSystem.screensFlipped
@ reads 0 in every PC savestate, so that is exactly what was happening: forcing
@ POWCNT1 every frame from two different places still lost.
@
@ Setting the flag instead makes the game route the way we want on its own, from
@ wherever it re-asserts. Every entry in sMapLoadModes has switchScreens = FALSE,
@ so the game only ever drives this to 0; nothing else fights us for it, and a
@ map change will reset it for free.
@ ---------------------------------------------------------------------------
    .global OneScreen_SetFlipped
    .thumb_func
OneScreen_SetFlipped:
    ldr     r1, =cfg_screens_flip
    ldr     r1, [r1]
    cmp     r1, #0
    beq     45f
    strb    r0, [r1]
45: bx      lr
    .align  2
    .pool

@ ---------------------------------------------------------------------------
@ void OneScreen_AppIntent(void)
@ Apply app_table whenever the running app changes. Edge-triggered, so it does
@ not fight a manual L+R and costs a table walk only on transitions.
@ ---------------------------------------------------------------------------
    .global OneScreen_AppIntent
    .thumb_func
OneScreen_AppIntent:
    push    {r4, lr}
    ldr     r0, =cfg_app_callback
    ldr     r0, [r0]
    ldr     r0, [r0]
    ldr     r1, =last_app
    ldr     r2, [r1]
    cmp     r0, r2
    beq     33f                     @ same app as last frame
    str     r0, [r1]

    @ An application just handed the field back (flying is the case that needs
    @ this): arm a short window to put the world on top. Poll consumes it.
    ldr     r1, =cfg_field_callback
    ldr     r1, [r1]
    cmp     r0, r1
    bne     34f
    ldr     r1, =field_restore
    movs    r2, #FIELD_RESTORE_FRAMES
    str     r2, [r1]

34: ldr     r4, =app_table
30: ldr     r2, [r4]
    cmp     r2, #0
    beq     33f                     @ end of table: not listed
    cmp     r2, r0
    beq     32f
    adds    r4, #8
    b       30b
32: ldr     r0, [r4, #4]
    bl      OneScreen_SetSwap
33: pop     {r4, pc}
    .align  2
    .pool

@ ---------------------------------------------------------------------------
@ int OneScreen_OakExec(OverlayManager *manager, int *proc_state)
@ Oak's opening speech - see the OAK_ constants above for the state map.
@ Runs the app first, then routes, so ours is the last word for the frame.
@ ---------------------------------------------------------------------------
    .global OneScreen_OakExec
    .thumb_func
OneScreen_OakExec:
    push    {r4, r5, lr}
    movs    r4, r1                  @ &proc_state, to survive the call
    ldr     r3, =cfg_oak_exec_orig
    ldr     r3, [r3]
    blx     r3
    movs    r5, r0                  @ keep its return value
    ldr     r4, [r4, #OAK_DATA_OFF] @ manager->data, read after so it exists
    cmp     r4, #0
    beq     61f
    ldr     r0, [r4, #OAK_STATE_OFF]
    cmp     r0, #OAK_TUTORIAL_HI
    bls     63f                     @ the tutorial menu, drawn on engine B
    subs    r0, #OAK_GENDER_LO
    cmp     r0, #(OAK_GENDER_HI - OAK_GENDER_LO)
    bhi     60f
63: movs    r0, #1                  @ ...as is the gender picker
    b       62f
60: movs    r0, #0                  @ the speech and the INFOS pages: engine A
62: bl      OneScreen_SetSwap
61: movs    r0, r5
    pop     {r4, r5, pc}
    .align  2
    .pool

@ ---------------------------------------------------------------------------
@ The field's running task. pret:
@
@     struct TaskManager { TaskManager *prev; TaskFunc func; u32 state;
@                          void *env; u32 unk10; void *unk14;
@                          FieldSystem *fieldSystem; ... };
@
@ reached as sFieldSysPtr -> fieldSystem->taskman (+0x10). The struct confirms
@ itself: +0x18 reads back the FieldSystem pointer we started from.
@
@ Measured across three savestates:
@     X menu open   taskman 0x022C01D8, func 0x0203BEF1  <- ARM9: Task_StartMenu
@     no menu       taskman NULL
@     after Dig     taskman 0x022C01D8, func 0x0224C3CD  <- an OVERLAY: a script
@
@ Two facts are used, and only these two:
@
@   * taskman == NULL means the field is idle, so a press of X will actually
@     open the menu. That is the game's own gate, which is why a ladder swallows
@     the press.
@   * an OVERLAY-resident task means a script owns the field. Scripts live in
@     overlays; the menu lives in ARM9.
@
@ What is NOT safe is the converse - reading "func is in ARM9" as "the menu is
@ open". That was tried and broke several things at once: the cave-name card and
@ the flight sequence are ARM9 field tasks too, so the menu was forced over both.
@ ARM9 means "not a script", nothing more.
@ ---------------------------------------------------------------------------
    .thumb_func
OneScreen_TaskMan:                  @ -> r0 = fieldSystem->taskman, or 0
    ldr     r0, =cfg_field_sys
    ldr     r0, [r0]
    cmp     r0, #0
    beq     55f
    ldr     r0, [r0]                @ sFieldSysPtr
    cmp     r0, #0
    beq     55f
    ldr     r0, [r0, #TASKMAN_OFF]
    bx      lr
55: movs    r0, #0
    bx      lr
    .align  2
    .pool

@ int OneScreen_MenuGone(void) - 1 when the menu certainly is NOT on screen.
@
@ Deliberately one-sided. It answers "definitely gone", never "definitely open",
@ so it can only ever lower the latch. Two grounds, both sound:
@     no task at all   - the menu is a task, so no task means no menu
@     an overlay task  - a script owns the field; scripts live in overlays
@ ARM9 tasks return 0 here, i.e. "don't know", which is the honest answer and
@ the one v28 got wrong by reading them as "the menu is open".
    .thumb_func
OneScreen_MenuGone:
    push    {r4, lr}
    bl      OneScreen_TaskMan
    cmp     r0, #0
    beq     58f                     @ no task running: the menu cannot be up
    movs    r4, r0
    ldr     r0, [r4, #TASK_FUNC_OFF]
    ldr     r1, =cfg_field_callback
    ldr     r1, [r1]
    subs    r1, #1                  @ overlay 1's base = where overlay RAM starts
    cmp     r0, r1
    bhs     58f                     @ an overlay task: a script owns the field

    @ It is an ARM9 task, so we cannot tell from the address alone. But if it is
    @ Task_StartMenu we can ask the menu itself, and its exit states say it is
    @ leaving even though it is still on screen - the Dig / Escape Rope flash.
    ldr     r1, =cfg_start_menu_task
    ldr     r1, [r1]
    cmp     r1, #0
    beq     57f                     @ the patcher could not vouch for it
    cmp     r0, r1
    bne     57f
    ldr     r0, [r4, #TASK_ENV_OFF] @ the StartMenuTaskData
    cmp     r0, #0
    beq     57f
    ldrh    r0, [r0, #STARTMENU_STATE_OFF]
    subs    r0, #STARTMENU_EXIT_LO
    cmp     r0, #(STARTMENU_EXIT_HI - STARTMENU_EXIT_LO)
    bhi     57f
58: movs    r0, #1
    pop     {r4, pc}
57: movs    r0, #0
    pop     {r4, pc}
    .align  2
    .pool

@ ---------------------------------------------------------------------------
@ int OneScreen_ScriptMenu(void)
@ Returns 1 if a field script menu is up and we routed it to the top screen.
@ Applied every frame while it is up, because the field redraws underneath it.
@ ---------------------------------------------------------------------------
    .global OneScreen_ScriptMenu
    .thumb_func
OneScreen_ScriptMenu:
    push    {r4, lr}
    ldr     r0, =cfg_field_sys
    ldr     r0, [r0]
    cmp     r0, #0
    beq     44f
    ldr     r0, [r0]                @ sFieldSysPtr
    cmp     r0, #0
    beq     44f                     @ no field system yet (boot, menus)
    ldr     r0, [r0, #FIELD_MENU_OFF]
    ldr     r4, =script_menu
    cmp     r0, #0
    beq     42f

    movs    r0, #1                  @ a script menu is up -> bottom screen on top
    str     r0, [r4]
    bl      OneScreen_SetSwap
    movs    r0, #1
    pop     {r4, pc}

42: ldr     r0, [r4]
    cmp     r0, #0
    beq     44f                     @ it was never ours
    movs    r0, #0                  @ the menu closed: put the world back
    str     r0, [r4]
    bl      OneScreen_SetSwap
44: movs    r0, #0
    pop     {r4, pc}
    .align  2
    .pool

@ ---------------------------------------------------------------------------
@ void OneScreen_Poll(void)
@ L+R swaps the screens anywhere. In the overworld, X brings the menu up with it
@ and B puts the world back - the field app draws that menu itself without
@ touching POWCNT1, so there is no transition to detect and it is driven from
@ the buttons the player already presses.
@ ---------------------------------------------------------------------------
    .global OneScreen_Poll
    .thumb_func
OneScreen_Poll:
    push    {r4, r5, r6, lr}
    ldr     r6, =pad_held
    ldr     r6, [r6]
    ldr     r4, =pad_new
    ldr     r4, [r4]

    @ --- L+R: manual swap, available everywhere ---
    ldr     r1, =TOGGLE_MASK
    movs    r0, r6
    ands    r0, r1
    cmp     r0, r1
    bne     10f                     @ not both held
    movs    r0, r4
    ands    r0, r1
    cmp     r0, #0
    beq     10f                     @ neither is new: still held from before
    bl      OneScreen_Toggle
    ldr     r0, =bt_menu_up         @ stop the battle logic re-asserting, so a
    movs    r1, #0                  @ manual override sticks until you press the
    str     r1, [r0]                @ D-pad again or the phase changes

10: ldr     r5, =menu_swapped
    ldr     r0, =cfg_app_callback
    ldr     r0, [r0]
    ldr     r0, [r0]
    ldr     r1, =cfg_field_callback
    ldr     r1, [r1]
    cmp     r0, r1
    beq     11f
    @ Not the overworld. KEEP the latch, so a trip into the bag/party/Pokédex and
    @ back leaves the menu on the top screen where you left it - the field
    @ re-asserts its own layout on return, which is what put the menu back on the
    @ bottom. Drop the latch only in battle, where the battle logic owns the
    @ screens.
    ldr     r1, =cfg_ov12_lo
    ldr     r1, [r1]
    cmp     r0, r1
    blo     19f
    ldr     r1, =cfg_ov12_hi
    ldr     r1, [r1]
    cmp     r0, r1
    bhs     19f
    movs    r0, #0
    str     r0, [r5]
    b       19f

    @ A script owns the bottom screen (PC option list, shop, NPC choice): it
    @ holds the routing for as long as it is up, and puts the world back after.
11: bl      OneScreen_ScriptMenu
    cmp     r0, #0
    bne     19f

    @ X opens the menu - but only if the field was idle. On a ladder, mid script
    @ or during a cutscene the game discards the press and no menu appears, and
    @ we used to swap anyway. prev_task is LAST frame's taskman, so this does not
    @ race the same frame's handling of the press.
    ldr     r1, =KEY_X
    movs    r0, r4
    ands    r0, r1
    cmp     r0, #0
    beq     12f
    ldr     r0, [r5]
    cmp     r0, #0
    bne     13f                     @ the menu is UP: X closes it, always allow.
                                    @ Gating this was wrong - with the menu open
                                    @ a task is by definition running, so the
                                    @ idle test below rejected every close and X
                                    @ had to be pressed twice.
    ldr     r0, =prev_task
    ldr     r0, [r0]
    cmp     r0, #0
    bne     19f                     @ the field was busy: no menu will open
    ldr     r0, [r5]
13: movs    r1, #1
    eors    r0, r1                  @ X toggles
    str     r0, [r5]
    bl      OneScreen_SetSwap
    b       19f

12: movs    r0, r4
    movs    r1, #KEY_B
    ands    r0, r1
    cmp     r0, #0
    beq     15f
    ldr     r0, [r5]
    cmp     r0, #0
    beq     15f                     @ we did not swap: leave B alone
    movs    r0, #0
    str     r0, [r5]
    bl      OneScreen_SetSwap       @ B closed the menu: put the world back
    b       19f

    @ Hold the routing while the menu is open. Coming back from a sub-app makes
    @ the field re-apply its own layout, so a one-shot swap does not survive.
15: ldr     r0, [r5]
    cmp     r0, #0
    beq     16f

    @ ...unless the menu is demonstrably gone: a script took the field over, the
    @ way Dig and Escape Rope do, or no task is running at all. Either way nobody
    @ pressed B but the menu has ended. This only ever CLEARS the latch - nothing
    @ here can raise it - so it cannot put the menu over a cave card or a flight,
    @ which is what testing "any ARM9 task" did.
    bl      OneScreen_MenuGone
    cmp     r0, #0
    beq     14f
    movs    r0, #0
    str     r0, [r5]
    ldr     r1, =field_restore
    movs    r0, #FIELD_RESTORE_FRAMES
    str     r0, [r1]
    b       16f

14: ldr     r1, =field_restore      @ the menu owns the screen: drop any pending
    movs    r0, #0                  @ restore so it cannot fire later
    str     r0, [r1]
    movs    r0, #1
    bl      OneScreen_SetSwap
    b       19f

    @ No menu of ours is up. If an app just handed the field back, the layout it
    @ left behind is still in place - put the world on top.
16: ldr     r1, =field_restore
    ldr     r0, [r1]
    cmp     r0, #0
    beq     19f
    subs    r0, #1
    str     r0, [r1]
    movs    r0, #0
    bl      OneScreen_SetSwap

    @ Sample the field's task for next frame, so the X gate above reads the
    @ state BEFORE the press rather than after the game has handled it.
19: bl      OneScreen_TaskMan
    ldr     r1, =prev_task
    str     r0, [r1]
    pop     {r4, r5, r6, pc}
    .align  2
    .pool

@ ---------------------------------------------------------------------------
@ void OneScreen_Frame(void)
@ Replaces `bl 0x0200110C` at 0x02000DB0 in the main loop: run the original
@ call, then our per-frame work. The displaced call takes no arguments and its
@ return value is unused by the loop, so wrapping it is safe.
@ ---------------------------------------------------------------------------
    .global OneScreen_Frame
    .thumb_func
OneScreen_Frame:
    push    {lr}
    ldr     r3, =ORIG_LOOP_FN
    blx     r3
    bl      OneScreen_UpdatePad
    bl      OneScreen_AppIntent
.ifndef DISABLE_AUTO_BATTLE
    bl      OneScreen_AutoBattle
.endif
    bl      OneScreen_Poll
    bl      OneScreen_MapHold
    bl      OneScreen_PcHold        @ last word on routing, after Poll
    pop     {pc}
    .align  2
    .pool
