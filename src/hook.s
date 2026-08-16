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
DEF_BATTLE_EXEC_ORIG = 0x0203E3AD @ Battle_Main - see OneScreen_BattleExec

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

@ --- The top-screen command menu -------------------------------------------
@ Offsets into the live battle structs, all reached from the BattleSystem the
@ battle app's exec trampoline hands us. Taken from pret's headers, and the ones
@ that matter are pinned by fields the decomp named after their own offsets:
@
@   struct BattleSystem (include/battle/battle.h:527)
@       +0x04 BgConfig *bgConfig      \ both confirmed independently in the retail
@       +0x08 Window   *window        / ov12: `ldr r0,[r4,#4]` / `ldr r1,[r4,#8]`
@       +0x19C BattleInput *battleInput   (unk17C[2] before it, unk1A0 after)
@
@   struct BattleInput (include/battle/battle_input.h:169)
@       +0x66B s8 curMenuId       (unused_668, unused_669 before; unk66F after)
@       +0x6B4 BattleMenuCursor { u8 enabled; s8 menuY; s8 menuX; u8 unused; }
@
@ Both offsets are 0x20 HIGHER than walking pret's struct suggests, which is the
@ drift battle_input.h:168 warns about ("at some point here my counting was off
@ so some of the listed offsets may be wrong"). Reading the computed 0x66B gave a
@ zero byte, and a 160-byte window around it contained no menu id at all.
@
@ The real values were measured out of the ROM instead of guessed. Offsets this
@ large cannot be reached by a Thumb immediate, so every access to these fields
@ has to load the offset from a literal pool - which makes the pool a census of
@ the struct. Scanning ov12's word-aligned literals in [0x500,0x800) shows:
@
@     0x68a x9   0x68b x6   0x68c x5   0x68d x1   0x68e x3   0x68f x2
@
@ six consecutive single-byte offsets, which is exactly pret's run of six u8
@ fields - battlerType, curMenuId, monTargetType, gender, isTouchDisabled,
@ unk66F. What confirms the alignment rather than merely fitting it: 0x688 and
@ 0x689 are absent from the pool entirely, and those are the two pret calls
@ unused_668 / unused_669. Unreferenced fields leave no literals.
@
@ The same +0x20 lands the cursor on 0x6d4, and the fields after it corroborate:
@ 0x6d8 (keyPressed, x8), 0x6dc (tutorial.finger, x7), 0x6e4/0x6e8/0x6ec (the
@ three ManagedSprite pointers that close the struct, x5/x1/x2). Two fields
@ agreeing on one delta, with the gaps in the right places.
@
@ Identical in IPGF, IPKF and IPKE - these are code-derived, so unlike data they
@ do not move between regions.
BATTLE_INPUT_OFF  = 0x19C
BI_CURMENU_OFF    = 0x68B
BI_CURSOR_OFF     = 0x6D4

@ The cursor offset is the one value here that the literal census cannot settle.
@ curMenuId was pinned by a run of six consecutive byte offsets with the two
@ unused ones missing; menuCursor has no such signature, and three candidates
@ (0x6d4, 0x6d8, 0x6dc) all have plausible reference counts and plausible
@ neighbours. Picking one and shipping it is how the highlight ended up welded to
@ ATTAQUE: a wrong offset reads bytes that clamp to menuY 0, which is the whole
@ top row.
@
@ So BI_CURSOR_OFF is only a starting guess, and the hook corrects it from the
@ game itself - see OneScreen_BattleLearn. The window it watches has to contain
@ every candidate.
BI_WIN_BASE  = 0x680
BI_WIN_SIZE  = 128              @ 0x680..0x700
KEY_UPDOWN   = 0x0C0            @ up | down

@ enum BattleMenuID (include/constants/battle_menu.h:58). Ids 1..8 are ALL the
@ root command menu, not just the two the enum bothers to name: sBattleMenuTemplates
@ (src/battle/battle_input.c:581) gives every one of them
@ sTouchscreenRectMainMenuButtons and BattleInput_CursorMove_MainMenu, and 3 and 4
@ differ from 1 and 2 only in calling BattleInput_CreateMainMenuObjects instead of
@ ...Initial - which is to say they are the "put the menu back up" states you land
@ on after backing out of the move list or the bag. 5 and 6 get named outright in
@ the cursor mover's own switch.
@
@ Testing only 1 and 2 is what made backing out of a submenu leave the screens
@ swapped with no labels: the menu was up, we just did not recognise the id.
@ 9/10 are Pal Park, 11+ are the move list, target select and the prompts.
@ -1 is BATTLE_MENU_NONE, which is live while the battle intro text plays.
BATTLE_MENU_ROOT_LO = 1
BATTLE_MENU_ROOT_HI = 8

@ 13..17 are the binary prompts - YES_NO, KEEP_FORGET_MOVE, GIVE_UP_ON_MOVE,
@ SWITCH_OR_FLEE, SWITCH_OR_KEEP. sBattleMenuTemplates gives all five
@ BattleInput_CursorMove_TwoOptionsMenu, whose cursor is one column by two rows
@ (BattleCursor_CheckKeyInput(cursor, 1, 2, ...)), so menuY alone picks the
@ answer. The bottom screen words them differently each time - "Changer de
@ Pokemon" against "Continuer le combat" - but the choice underneath is always
@ the same shape, so they all get the one Oui/Non pair, stacked to match the way
@ the D-pad moves.
BATTLE_MENU_TWO_LO = 13
BATTLE_MENU_TWO_HI = 17

@ Where the boxes live is not stated here at all - the blob carries an absolute
@ destination address per tile row, because the battle message window and Oak's
@ dialog box sit on different character bases (BG1 charBase 1 at 0x06004000,
@ Oak's MAIN_0 at 0x06018000). Confirmed for the battle side by dumping BG1CNT
@ and engine A's DISPCNT live mid-battle; Oak's comes from its own BgTemplate.
LABEL_MAGIC  = 0x424C5331       @ "1SLB"

@ The blob holds image sets with geometry records at +8. Each 28-byte record is:
@ data offset, bytes per image, bytes per tile row, image count, then four
@ absolute destination addresses. More than one geometry can point at the same
@ image data: the battle and field Oui/Non boxes use the same pixels at different
@ MAIN-engine character addresses. The hook carries no dimensions of its own,
@ so moving or resizing a box is a change to onescreen/labels.py alone.
@
@ An image is named by a single byte, (set << 4) | index, which is what bt_drawn
@ and bt_lock hold. The last image of each set is all paper and takes that box
@ down - a separate box for the yes/no prompt is the whole point, because the
@ blit paints everything in its area and a wide one erases the right-hand end of
@ any question long enough to reach it.
LABEL_GEO_SIZE = 28
LABEL_GEO_YN   = 1              @ (1 << 4) | 0 = top choice, | 1 = bottom
LABEL_GEO_OAK    = 2            @ Oak's yes/no, stacked - the generic multichoice
                                @ handler moves on UP and DOWN
LABEL_GEO_GENDER = 3            @ boy/girl, side by side - the gender handler moves
                                @ on LEFT and RIGHT, so stacking implied wrong keys
LABEL_GEO_FIELD  = 4            @ field-dialog Oui/Non; aliases LABEL_GEO_YN pixels
LABEL_GEO_COUNT  = 5
@ Reserved space for the label images; the patcher refuses rather than overrun it.
@ The five geometry records, start-menu record and four unique localized image
@ sets fit here with headroom. The field geometry aliases the battle Yes/No set.
LABEL_BLOB_SIZE = 22528         @ reserved; the patcher refuses rather than overrun it

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

@ Drawing that menu onto the world instead of swapping to it. Three fields carry
@ everything needed, and all three were read out of a live savestate with the
@ menu open (out/beta-ui.ml1) rather than trusted from the decomp alone:
@
@   FieldSystem +0xD3   the cursor. NOT in StartMenuTaskData - the touch overlay
@                       owns it (ov27_0225B404 writes it on every D-pad move) and
@                       start_menu.c only reads it. Read 0 with POKEDEX lit. It
@                       counts only the entries you HAVE, so it is an index into
@                       the compacted list, not a grid slot.
@   StartMenuTaskData +0x34C  inhibitIconFlags, the game's own answer to which
@                       entries exist, computed once when the menu opens
@                       (src/start_menu.c:288). This is what the panel is built
@                       from. selectionToAction[] at +0x3A looks like the obvious
@                       source and is a trap: past the real entries it holds
@                       zeros, which read as POKEDEX and drew that word twice.
SM_CURSOR_OFF = 0xD3
SM_INHIBIT_OFF = 0x34C          @ StartMenuTaskData.inhibitIconFlags
SM_NORMAL_BIT = 8               @ DISABLE_RETIRE; see OneScreen_StartMenu

@ The panel's record in the label blob, and the offsets inside it. Written by
@ onescreen/labels.py::_startmenu; the layout is documented there.
SM_RECORD_OFF = 148
SM_TILES_OFF = 0                @ u32 blob offset of the strip pool
SM_TILES_BYTES = 4
SM_TILES_DEST = 8
SM_PAL_OFF = 12
SM_PAL_DEST = 16
SM_BASE_TILE = 20               @ u16
SM_STRIP_TILES = 22             @ u8
SM_CELL_W = 23
SM_CELL_H = 24
SM_N_CELLS = 25
SM_PAL_NORM = 26
SM_PAL_HI = 27
SM_CELL_LABEL = 32              @ u8 cell_label[8], 0xFF where nothing lives
SM_CELL_BIT = 40                @ u8 cell_bit[8], the inhibit bit gating each
SM_ROWS_OFF = 48                @ u32 cell_rows[16], absolute tilemap addresses
SM_BLANK = 29                   @ u8 index of the all-paper strip
SM_PAL_BYTES = 64               @ both palettes, which the builder keeps adjacent
SM_FRAME_OFF = 0x70             @ u32 blob offset of the border's tilemap
SM_FRAME_BASE = 0x74            @ u32 tilemap address of its top-left cell
SM_FRAME_ROWS = 0x78            @ u8; past ldrb's immediate, so loaded by register
SM_FRAME_COLS = 0x79
SM_MAP_STRIDE = 64              @ bytes per tilemap row: 32 entries of 2

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
@ Oak's own two-option prompts. OakSpeechData is decompiled
@ (include/oaks_speech_internal.h), and its OakSpeechMultichoice sits inline at
@ +0x160 - anchored by filler_148[0x18] immediately before it, and by unk_080 and
@ unk_114 earlier in the struct, all three named after their own offsets:
@
@     +0x160 unk_0        +0x161 numOptions
@     +0x162 inPadMode    +0x163 cursorPos
@
@ so the count and the live selection are one struct away from the pointer the
@ exec trampoline is already handed every frame. That pairing is what the field
@ prompt never had, and it is why this one is tractable.
@
@ The states come from the enum in src/oaks_speech.c, and only the three that
@ actually take input are drawn on - the setup and fade states around them would
@ otherwise flash a prompt the player cannot answer yet.
OAK_MENU_OFF     = 0x160
OAK_NUMOPTS_OFF  = 0x161
OAK_CURSOR_OFF   = 0x163
OAK_GENDER_PICK    = 65         @ GENDER_SELECT_MENU_HANDLE_INPUT
OAK_CONFIRM_GENDER = 69         @ CONFIRM_GENDER_YESNO_HANDLE_INPUT
OAK_CONFIRM_NAME   = 98         @ CONFIRM_NAME_YESNO_HANDLE_INPUT

@ The states that lead into each of those. The game has already drawn the dialog
@ box by then, complete with the "look at the bottom screen" icon in the corner
@ our prompt is about to occupy - so without this the icon gets a few frames to
@ itself and visibly flashes before the prompt lands. Blitting the box's own
@ all-paper image through the lead-in covers it, without showing a prompt the
@ player cannot answer yet.
@
@     62 WAIT_FADE_OUT_TO_ASK_GENDER .. 64 WAIT_FADE_IN_GENDER_SELECT_MENU
@     66 PREPARE_ASK_CONFIRM_GENDER  .. 68 CONFIRM_GENDER_YESNO_INIT_MENU
@     96 PROMPT_NAME_RESTORE_GRAPHICS .. 97 CONFIRM_NAME_YESNO_INIT_MENU
OAK_GENDER_PRE_LO  = 62
OAK_GENDER_PRE_HI  = 64
OAK_CONFIRM_PRE_LO = 66
OAK_CONFIRM_PRE_HI = 68
OAK_NAME_PRE_LO    = 96
OAK_NAME_PRE_HI    = 97

@ The "look at the bottom screen" prompt is not part of the dialog box at all -
@ it is data->sprites[3], an object drawn above the background, which is why
@ covering the box never hid it. The game shows it while Oak waits for you and
@ hides it itself at SETUP_GENDER_SELECT_MENU; the old code swapped the screen
@ away for those frames, so it was simply never seen. Now that Oak keeps the
@ screen it is visible right up to the moment the prompt lands, and flashes.
@
@ So it gets hidden a few states early. This is the only place the hook writes
@ game state other than gSystem.screensFlipped, and it is about as narrow a write
@ as exists: one byte that only affects whether an object is rendered. Safe
@ against the game's own bookkeeping because GF_ASSERT compiles to nothing
@ without PM_KEEP_ASSERTS, so the drawFlag checks around Sprite_SetDrawFlag
@ generate no code in a retail build - the game simply sets it again later.
@
@ sprites[6] begins at +0xD8 (spriteRenderer +0xD0, spriteGfxHandler +0xD4), so
@ sprites[3] is +0xE4, and Sprite.drawFlag is +0x34 - both from headers whose
@ neighbouring fields are annotated with their own offsets.

OAK_STATE_OFF = 0x0C            @ OakSpeechData.state
OAK_DATA_OFF = 0x08             @ manager->data, from &proc_state (+0x14)
OAK_TUTORIAL_HI = 7             @ 0..7: the tutorial menu

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
@ Mode 3 is refined at runtime: binary states stay on the world, list states swap.
FIELD_TOUCH_TASK_OFF = 0xD8     @ FieldSystem -> outer bottom-screen SysTask
SYS_TASK_DATA_OFF = 0x10        @ SysTask.data

@ The outer task owns transitions between bottom-screen modes. Its 16-byte data
@ block is known from ov01_021F68DC/ov01_021F69C0.
FIELD_OUTER_MODE_OFF  = 0x00
FIELD_OUTER_STATE_OFF = 0x01
FIELD_OUTER_NEXT_OFF  = 0x02
FIELD_OUTER_CHILD_OFF = 0x04
FIELD_OUTER_FS_OFF    = 0x08
FIELD_OUTER_LAST_OFF  = 0x0C
FIELD_OUTER_IDLE      = 1
FIELD_OUTER_TRANS_LO  = 2
FIELD_OUTER_TRANS_HI  = 7
FIELD_TOUCH_MODE      = 3

@ Mode 3 is overlay 27's green touch controller. GetMenuChoice selects state 3;
@ MenuExec selects state 7. The live choice is a word, not the ListMenu2D field
@ the abandoned experiment followed.
FIELD_CHILD_STATE_OFF = 0x00
FIELD_CHILD_FS_OFF    = 0x24
FIELD_CHILD_CHOICE_OFF = 0x394
FIELD_CHILD_BINARY_LO = 3
FIELD_CHILD_BINARY_HI = 5
FIELD_CHILD_BINARY_DONE = 6
FIELD_CHILD_LIST_LO   = 7
FIELD_CHILD_STATE_HI  = 11


@ --------------------------------------------------------------------------
@ Data. ITCM is RAM, so all of this is writable at runtime.
@ --------------------------------------------------------------------------
    .global OneScreen_Signature
OneScreen_Signature:
    .ascii  "1SGS"
    .word   0x00000018          @ payload version

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
cfg_battle_exec_orig: .word DEF_BATTLE_EXEC_ORIG

pad_held:       .word 0
pad_new:        .word 0         @ newly pressed this frame
prev_pad:       .word 0

menu_swapped:   .word 0         @ 1 while WE swapped for the overworld X menu
last_app:       .word 0

bt_phase:       .word NO_STATE  @ last battle phase acted on
bt_menu_last:   .word NO_STATE  @ last menu id acted on, for edge detection
bt_manual:      .word 0         @ 1 while an L+R override is holding, in battle
bt_system:      .word 0         @ live BattleSystem*, or 0 outside a battle
bt_drawn:       .word -1        @ label image currently blitted, -1 = nothing
bt_cursor_off:  .word BI_CURSOR_OFF  @ learned; see OneScreen_BattleLearn
bt_have_prev:   .word 0         @ 1 once bt_prev holds last frame's window
bt_lock:        .word -1        @ image frozen at the moment A was pressed, -1 = free
oak_drawn:      .word -1        @ prompt image in Oak's dialog box, -1 = none
oak_data:       .word 0         @ diagnostics: OakSpeechData, its state,
oak_state:      .word -1        @ sprites[3] and that sprite's drawFlag, so a

dex_last:       .word -1        @ last Pokedex proc_state acted on
dex_mode:       .word 0         @ 0 = grid/info side, 1 = the area map
pc_frames:      .word 0         @ frames left to hold the PC box routing
script_menu:    .word 0         @ 1 while we own routing for a field script menu
field_yn_drawn: .word -1        @ field choice copied into MAIN_3, -1 = nothing
field_restore:  .word 0         @ frames left to force the world back on top
map_frames:     .word 0         @ counts down once the fly map stops running
map_pending:    .word 0         @ frames left waiting for the field to pick up
prev_task:      .word 0         @ last frame's fieldSystem->taskman
sm_drawn:       .word 0         @ 1 once the X menu's tiles and palettes are in VRAM

@ Kept below the word variables above, not among them: tools/savestate.py reads
@ that run as a flat array of words and a six-byte table in the middle of it
@ would silently shift every name after it.
@
@ sCursorArrayMainMenu (src/battle/battle_input.c:281) flattened to
@ [menuY*3 + menuX], mapping the game's 2x3 cursor grid onto our four label
@ images. FIGHT spans the whole top row; the bottom row is BAG, RUN, POKEMON
@ left to right - which is why the labels are drawn in that arrangement rather
@ than a 2x2. Values are image indices: 0 FIGHT, 1 BAG, 2 POKEMON, 3 RUN.
cursor_cmd:
    .byte   0, 0, 0
    .byte   1, 3, 2
    .align  2

@ Last frame's copy of the window OneScreen_BattleLearn watches.
bt_prev:        .space BI_WIN_SIZE



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
@ The screen no longer moves while you are choosing. The four commands are drawn
@ onto the battle scene itself (OneScreen_BattleDraw), so there is nothing to
@ raise and nothing to time out - the routing only changes once you have actually
@ picked something and the game needs a screen we cannot draw on.
@
@   turn executing              -> battle scene on top
@   root command menu (1..8)    -> battle scene on top, commands drawn over it
@   a yes/no prompt (13..17)    -> battle scene on top, Oui/Non drawn over it
@   bag or party (overlay 8)    -> hand the screen over, every frame
@   any other menu (11, 12, ..) -> hand the screen over, every frame
@   no menu yet (-1 / 0)        -> leave the scene alone; the intro is playing
@
@ What this replaces: the menu used to come up on a D-pad or A press and step
@ aside after ~1 s of stillness, which meant guessing at intent from the pad. The
@ game's own menu id says what is happening, so none of that guessing survives.
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

    @ --- awaiting a command: the menu id decides everything ---
    @ The old rule watched the pad and guessed at intent - a D-pad or A press
    @ raised the whole menu, and ~1 s of stillness dropped it again. It no longer
    @ has to guess, because the labels are on the battle scene itself: the screen
    @ only changes when the player has actually chosen something, and the game
    @ says when that happened by moving off its root menu.
    @
    @ Reading the menu id also retires the battle-intro problem for free. The
    @ phase proxy reads "awaiting a command" from the moment overlay 10 loads,
    @ which is while the intro text is still playing - but curMenuId is
    @ BATTLE_MENU_NONE until the menu actually opens, so mashing A through the
    @ intro now does nothing instead of pinning the menu for the rest of the
    @ fight.
    bl      OneScreen_BattleMenuId
    movs    r5, r0

    @ An L+R override holds until the menu you are on changes - moving into the
    @ move list, or backing out of it, hands control back to us. Without this the
    @ escape hatch would be useless in battle, since the routing is now
    @ re-asserted every frame rather than once.
    ldr     r0, =bt_menu_last
    ldr     r1, [r0]
    cmp     r1, r5
    beq     27f
    str     r5, [r0]
    ldr     r0, =bt_manual
    movs    r1, #0
    str     r1, [r0]
27: ldr     r0, =bt_manual
    ldr     r0, [r0]
    cmp     r0, #0
    bne     28f                     @ the player has taken the screen; leave it

    @ The bag and the party are their own overlay, and they do not move
    @ curMenuId off the root menu while they are up - so going by the menu id
    @ alone left them drawing on the bottom screen the first time they opened.
    @ The overlay id says it outright, and it is the same signal the old timeout
    @ logic used for exactly this case.
    bl      OneScreen_BattleSubOpen
    cmp     r0, #0
    bne     25f

    subs    r0, r5, #BATTLE_MENU_ROOT_LO
    cmp     r0, #(BATTLE_MENU_ROOT_HI - BATTLE_MENU_ROOT_LO)
    bls     26f                     @ 1..8: the root command menu
    movs    r0, r5                  @ 3-bit immediate cannot reach 13
    subs    r0, #BATTLE_MENU_TWO_LO
    cmp     r0, #(BATTLE_MENU_TWO_HI - BATTLE_MENU_TWO_LO)
    bls     26f                     @ 13..17: a yes/no prompt, drawn on the scene
    cmp     r5, #0
    ble     28f                     @ -1 / 0: no menu is up, leave the scene alone

    @ A submenu is open - the move list, target select. That is drawn on engine
    @ B, so hand the screen over, and keep handing it over: these sub-screens
    @ re-assert the routing themselves as they open, so a one-shot swap gets
    @ undone the moment you go a level deeper.
25: movs    r0, #1
    bl      OneScreen_SetSwap
    b       28f

    @ The root command menu. Keep the battle scene on the top screen - the four
    @ commands are drawn onto it rather than replacing it.
26: movs    r0, #0
    bl      OneScreen_SetSwap
    b       28f

29: movs    r0, #NO_STATE           @ not in a battle: re-arm for next time
    str     r0, [r4]
    movs    r0, #0                  @ drop the BattleSystem: the heap it lives
    ldr     r1, =bt_system          @ in is freed when the battle ends
    str     r0, [r1]
    bl      OneScreen_ResetBattleUi
28: pop     {r4, r5, pc}
    .align  2
    .pool

@ ---------------------------------------------------------------------------
@ int OneScreen_BattleMenuId(void)
@   -> r0 = battleInput->curMenuId, or BATTLE_MENU_NONE (-1) if there is no
@      live battle to read it from.
@
@ Returning -1 for "cannot tell" is deliberate: -1 is already the game's own
@ "no menu is up" value, and both cases want the same treatment - leave the
@ battle scene alone and draw nothing.
@ ---------------------------------------------------------------------------
    .thumb_func
OneScreen_BattleMenuId:
    ldr     r0, =bt_system
    ldr     r0, [r0]
    cmp     r0, #0
    beq     31f
    ldr     r1, =BATTLE_INPUT_OFF
    ldr     r0, [r0, r1]
    cmp     r0, #0
    beq     31f
    ldr     r1, =BI_CURMENU_OFF
    ldrsb   r0, [r0, r1]
    bx      lr
31: movs    r0, #0
    mvns    r0, r0                  @ -1
    bx      lr
    .align  2
    .pool

@ int OneScreen_BattleSubOpen(void) -> 1 while a battle sub-screen owns engine B
@ (bag category, item list, party). This is the overlay id, not the menu id: the
@ bag and party run as overlay 8 and leave curMenuId sitting on the root menu, so
@ the menu id cannot see them.
    .thumb_func
OneScreen_BattleSubOpen:
    ldr     r0, =cfg_battle_state
    ldr     r0, [r0]
    ldrb    r0, [r0]
    cmp     r0, #BATTLE_STATE_SUB
    beq     63f
    movs    r0, #0
    bx      lr
63: movs    r0, #1
    bx      lr
    .align  2
    .pool

@ int OneScreen_BattleYesNo(void) -> the label image for a two-option prompt.
@ One column, two rows, so menuY alone is the answer.
    .thumb_func
OneScreen_BattleYesNo:
    ldr     r0, =bt_system
    ldr     r0, [r0]
    cmp     r0, #0
    beq     64f
    ldr     r1, =BATTLE_INPUT_OFF
    ldr     r0, [r0, r1]
    cmp     r0, #0
    beq     64f
    ldr     r1, =bt_cursor_off
    ldr     r1, [r1]
    adds    r0, r0, r1
    ldrb    r0, [r0, #1]            @ menuY
    cmp     r0, #1
    bls     65f
64: movs    r0, #0
65: adds    r0, #(LABEL_GEO_YN << 4)
    bx      lr
    .align  2
    .pool

@ ---------------------------------------------------------------------------
@ void OneScreen_BattleLearn(BattleInput *bi)
@
@ Work out where BattleMenuCursor really is, by watching the game move it.
@
@ pret's offsets drift in this part of the struct (battle_input.h:168) and the
@ literal census that pinned curMenuId cannot separate the cursor from its
@ neighbours. Rather than ship a guess, watch what actually changes: on a frame
@ where UP or DOWN was pressed on the root menu, the game has already run and
@ menuY is the byte that moved. UP/DOWN only, never LEFT/RIGHT - the mover has a
@ special case where LEFT or RIGHT off FIGHT writes menuX *and* menuY
@ (battle_input.c:3778), so those frames cannot tell the two apart.
@
@ The candidate has to look like a BattleMenuCursor and not merely like a byte
@ that changed: menuY only ever holds 0 or 1, the byte before it is `enabled`
@ which is 1 while the cursor is live, and the byte after is menuX, at most 2.
@ Requiring exactly one match in the window means an ambiguous frame is skipped
@ rather than guessed at; the next press tries again.
@
@ Learned once and kept - it is a property of the ROM, not of the battle.
@ ---------------------------------------------------------------------------
    .thumb_func
OneScreen_BattleLearn:
    push    {r4, r5, r6, r7, lr}
    movs    r6, r0                  @ battleInput
    ldr     r7, =BI_WIN_BASE
    adds    r6, r6, r7              @ &bi[BI_WIN_BASE]
    ldr     r7, =bt_prev

    ldr     r0, =bt_have_prev
    ldr     r0, [r0]
    cmp     r0, #0
    beq     47f                     @ nothing to compare against yet

    ldr     r0, =pad_new
    ldr     r0, [r0]
    movs    r1, #KEY_UPDOWN
    ands    r0, r1
    cmp     r0, #0
    beq     47f

    movs    r2, #1                  @ offset; 0 has no byte before it
    movs    r4, #0                  @ candidate
    movs    r5, #0                  @ count
46: ldrb    r0, [r7, r2]            @ was
    ldrb    r1, [r6, r2]            @ is
    cmp     r0, r1
    beq     48f
    cmp     r0, #1
    bhi     48f                     @ menuY is 0 or 1, before and after
    cmp     r1, #1
    bhi     48f
    subs    r3, r2, #1
    ldrb    r0, [r6, r3]
    cmp     r0, #1
    bne     48f                     @ preceded by enabled == 1
    adds    r3, r2, #1
    ldrb    r0, [r6, r3]
    cmp     r0, #2
    bhi     48f                     @ followed by menuX <= 2
    movs    r4, r2
    adds    r5, #1
48: adds    r2, #1
    cmp     r2, #(BI_WIN_SIZE - 1)
    blo     46b

    cmp     r5, #1                  @ exactly one match, or leave it alone
    bne     47f
    ldr     r0, =BI_WIN_BASE
    adds    r0, r0, r4
    subs    r0, #1                  @ menuY is at +1 from the struct base
    ldr     r1, =bt_cursor_off
    str     r0, [r1]

47: movs    r2, #0                  @ remember this frame's window
49: ldrb    r0, [r6, r2]
    strb    r0, [r7, r2]
    adds    r2, #1
    cmp     r2, #BI_WIN_SIZE
    blo     49b
    ldr     r0, =bt_have_prev
    movs    r1, #1
    str     r1, [r0]
    pop     {r4, r5, r6, r7, pc}
    .align  2
    .pool

@ ---------------------------------------------------------------------------
@ int OneScreen_BattleCursor(void)
@   -> r0 = which command is highlighted, as a label image index 0..3.
@
@ Read from the game's own BattleMenuCursor rather than tracked here. The game
@ already moves this on the D-pad (BattleInput_CursorMove_MainMenu), remembers it
@ per battler between turns, and applies its own wrap rules at the edges; keeping
@ a second copy in the hook would only be a second thing to drift.
@
@ menuY/menuX are clamped rather than trusted. If BI_CURSOR_OFF turns out to be
@ pointing at the wrong bytes, a clamp keeps this returning a valid image instead
@ of indexing off the end of a six-byte table.
@ ---------------------------------------------------------------------------
    .thumb_func
OneScreen_BattleCursor:
    ldr     r0, =bt_system
    ldr     r0, [r0]
    cmp     r0, #0
    beq     34f
    ldr     r1, =BATTLE_INPUT_OFF
    ldr     r0, [r0, r1]
    cmp     r0, #0
    beq     34f
    ldr     r1, =bt_cursor_off
    ldr     r1, [r1]
    adds    r0, r0, r1
    ldrb    r1, [r0, #1]            @ menuY
    ldrb    r2, [r0, #2]            @ menuX
    cmp     r1, #1
    bls     32f
    movs    r1, #0
32: cmp     r2, #2
    bls     33f
    movs    r2, #0
33: lsls    r0, r1, #1
    adds    r0, r0, r1              @ menuY * 3
    adds    r0, r0, r2
    ldr     r1, =cursor_cmd
    ldrb    r0, [r1, r0]
    bx      lr
34: movs    r0, #0                  @ no cursor to read: show FIGHT selected
    bx      lr
    .align  2
    .pool

@ ---------------------------------------------------------------------------
@ void OneScreen_BattleMenu(int image)
@
@ Blit one of the label images into the battle message window. This is the whole
@ renderer: the labels were rasterised from the ROM's own strings and font at
@ patch time, so at runtime there is no font, no heap and no call into game code
@ - just tiles copied into VRAM the game has already allocated, mapped and
@ palettised for its own message box.
@
@ The destination is window[0] on GF_BG_LYR_MAIN_1, whose tiles are contiguous
@ per row and stride by the full 27-tile window width between rows. Those row
@ offsets are precomputed in the blob header, so this is four flat copies.
@
@ Called every frame while the menu is up, for the same reason SetSwap is: the
@ game rewrites this window whenever it prints, so the last write in the frame
@ has to be ours. 1792 bytes a frame.
@ ---------------------------------------------------------------------------
    .global OneScreen_BattleMenu
    .thumb_func
OneScreen_BattleMenu:
    push    {r4, r5, r6, r7, lr}
    ldr     r7, =OneScreen_Labels
    ldr     r1, [r7]
    ldr     r2, =LABEL_MAGIC
    cmp     r1, r2
    bne     39f                     @ blob never filled in: draw nothing at all
    ldrb    r6, [r7, #4]            @ rows

    lsrs    r1, r0, #4              @ which set
    ldrb    r2, [r7, #5]            @ number of geometry records
    cmp     r1, r2
    bhs     39f                     @ bad image code: stay inside the header
    movs    r2, #LABEL_GEO_SIZE
    muls    r1, r2
    adds    r1, #8
    adds    r1, r7, r1              @ -> its geometry record
    movs    r2, #15
    ands    r0, r2                  @ index within the set
    ldrh    r2, [r1, #10]           @ images in this set, including its wipe
    cmp     r0, r2
    bhs     39f                     @ bad index: stay inside its image data

    ldr     r3, [r1, #4]            @ bytes per image
    muls    r3, r0
    ldr     r2, [r1]                @ where this set's images start
    adds    r3, r3, r2
    adds    r4, r7, r3              @ src
    ldrh    r5, [r1, #8]            @ bytes per tile row
    movs    r7, r1                  @ 3-bit immediate cannot reach 12
    adds    r7, #12                 @ -> the row address table

    movs    r3, #0
35: cmp     r3, r6
    bhs     39f
    lsls    r0, r3, #2
    ldr     r0, [r7, r0]            @ absolute destination; the boxes sit on
    movs    r2, r5                  @ different character bases
36: ldmia   r4!, {r1}
    stmia   r0!, {r1}
    subs    r2, #4
    bne     36b
    adds    r3, #1
    b       35b
39: pop     {r4, r5, r6, r7, pc}
    .align  2
    .pool

@ int OneScreen_BattleWipe(int set) -> the image code that blanks that set's box.
@ The all-paper image is the last one of each set, so this is read from the blob
@ rather than known here.
    .thumb_func
OneScreen_BattleWipe:
    lsls    r3, r0, #4
    ldr     r1, =OneScreen_Labels
    ldrb    r2, [r1, #5]
    cmp     r0, r2
    bhs     38f                     @ missing geometry: return an invalid code
    movs    r2, #LABEL_GEO_SIZE
    muls    r0, r2
    adds    r0, #8
    adds    r0, r1, r0
    ldrh    r0, [r0, #10]           @ images in the set
    subs    r0, #1
    orrs    r0, r3
    bx      lr
38: movs    r0, #0
    mvns    r0, r0                  @ blitter's set-count check rejects -1
    bx      lr
    .align  2
    .pool

@ ---------------------------------------------------------------------------
@ void OneScreen_BattleDraw(int menu_id)
@
@ Only the root command menu draws labels, and it redraws them EVERY frame: the
@ game rewrites window[0] whenever the message printer runs, so a one-shot blit
@ gets painted over. This is the same rule the display routing already lives by.
@
@ Coming down is the opposite - wipe exactly ONCE, on the transition. Blitting
@ paper every frame would keep clearing the right-hand end of the message window
@ for the whole turn, which is where a long battle message goes. bt_drawn is what
@ separates the two: it holds the image on screen, or -1 for "we have taken our
@ labels down and the window is the game's again".
@ ---------------------------------------------------------------------------
    .thumb_func
OneScreen_BattleDraw:
    push    {r4, r5, lr}
    movs    r5, r0
    bl      OneScreen_BattleSubOpen
    cmp     r0, #0
    bne     41f                     @ the bag or party owns the screen
    subs    r1, r5, #BATTLE_MENU_ROOT_LO
    cmp     r1, #(BATTLE_MENU_ROOT_HI - BATTLE_MENU_ROOT_LO)
    bls     40f
    movs    r1, r5                  @ 3-bit immediate cannot reach 13
    subs    r1, #BATTLE_MENU_TWO_LO
    cmp     r1, #(BATTLE_MENU_TWO_HI - BATTLE_MENU_TWO_LO)
    bls     44f

    @ Nothing of ours belongs on screen: take down whichever box is up. The lock
    @ deliberately SURVIVES this. Going into the bag and back out is not a phase
    @ change, so without the lock the root menu would be redrawn from a cursor the
    @ game has not restored yet and ATTAQUE would flash. Holding the image the
    @ player last confirmed is also simply correct - the game restores the cursor
    @ to that same choice. ResetBattleUi drops it when the turn actually runs.
41: ldr     r0, =bt_drawn
    ldr     r1, [r0]
    adds    r2, r1, #1
    beq     42f                     @ was -1: nothing of ours on screen
    movs    r2, #0
    mvns    r2, r2
    str     r2, [r0]
    lsrs    r0, r1, #4              @ the set that is currently up
    bl      OneScreen_BattleWipe
    bl      OneScreen_BattleMenu
    b       42f

40: bl      OneScreen_BattleCursor
    b       45f
44: bl      OneScreen_BattleYesNo
45: movs    r4, r0

    @ Confirming a choice resets the game's cursor before the menu id changes, so
    @ for a frame or two the highlight would snap back to FIGHT and be visible as
    @ a flash on the way out. Freeze the image the player was actually looking at
    @ when they pressed A, and hold it until the menu changes or they move again.
    ldr     r0, =pad_new
    ldr     r0, [r0]
    ldr     r1, =DPAD_MASK
    ands    r1, r0
    cmp     r1, #0
    beq     46f
    ldr     r1, =bt_lock            @ moved: the lock is stale
    movs    r2, #0
    mvns    r2, r2
    str     r2, [r1]
46: ldr     r1, =bt_lock
    ldr     r2, [r1]
    adds    r3, r2, #1
    beq     47f
    lsrs    r3, r2, #4              @ a lock only holds within its own box:
    lsrs    r5, r4, #4              @ a command image means nothing to a yes/no
    cmp     r3, r5                  @ prompt, and would index the wrong set
    bne     47f
    movs    r4, r2                  @ locked: keep showing it
    b       48f
47: movs    r2, #KEY_A
    ands    r0, r2
    cmp     r0, #0
    beq     48f
    ldr     r0, =bt_drawn
    ldr     r0, [r0]
    adds    r2, r0, #1
    beq     48f                     @ nothing on screen yet to freeze
    str     r0, [r1]
    movs    r4, r0
48: ldr     r0, =bt_drawn
    str     r4, [r0]
    movs    r0, r4
    bl      OneScreen_BattleMenu
42: pop     {r4, r5, pc}
    .align  2
    .pool

@ void OneScreen_ResetBattleUi(void) - forget what is on screen, so nothing is
@ wiped on the way out of a battle whose window has already gone, and drop any
@ L+R override so the next battle does not start out of our hands.
    .thumb_func
OneScreen_ResetBattleUi:
    movs    r1, #0
    mvns    r1, r1
    ldr     r0, =bt_drawn
    str     r1, [r0]
    ldr     r0, =bt_menu_last
    str     r1, [r0]
    movs    r1, #0
    ldr     r0, =bt_manual
    str     r1, [r0]
    ldr     r0, =bt_have_prev       @ the window belongs to a battle that is over
    str     r1, [r0]
    movs    r1, #0                  @ and the frozen highlight to the last turn
    mvns    r1, r1
    ldr     r0, =bt_lock
    str     r1, [r0]
    bx      lr
    .align  2
    .pool

@ ---------------------------------------------------------------------------
@ int OneScreen_BattleExec(OverlayManager *manager, int *proc_state)
@
@ Installed in place of the battle application's exec pointer, the same trick
@ the Pokedex, PC box, fly map and Oak's speech already use. The battle is the
@ awkward one to find: every other application puts init/exec/exit *inside* the
@ overlay they name, but the battle's three are thin ARM9 wrappers (pret's
@ src/launch_application.c), so regions.find_overlay_template needs its
@ arm9_resident shape - three Thumb ARM9 pointers followed by `ovy_id == 12`.
@ Exactly one match in IPGF, IPKF and IPKE (FR/HG-FR 0x020FA468, US 0x020FA484),
@ with identical code pointers in all three, so this is region-neutral like the
@ rest.
@
@ What it is for: manager->data is the live BattleSystem, which is the root for
@ everything the top-screen command menu needs - the window it draws into, the
@ menu the player is on, and the cursor cell to highlight. Reading it here beats
@ hunting for it in RAM: the framework hands us the manager every frame.
@
@ Ordering follows OneScreen_OakExec: run the app's real exec FIRST, then read
@ manager->data. Two reasons - the pointer does not exist until Battle_Init has
@ run, and anything we draw has to land after the game's own window redraw for
@ the frame, or it gets painted over. `docs/AUDIT.md:133` calls that failure
@ class 4, and it is the reason the PC box needed a hold.
@
@ Nothing is drawn yet; this only captures the pointer, so the build is
@ behaviourally identical until the renderer lands.
@ ---------------------------------------------------------------------------
BATTLE_DATA_OFF = 0x08          @ manager->data, from &proc_state (+0x14)

    .global OneScreen_BattleExec
    .thumb_func
OneScreen_BattleExec:
    push    {r4, r5, lr}
    movs    r4, r1                  @ &proc_state, to survive the call
    ldr     r3, =cfg_battle_exec_orig
    ldr     r3, [r3]
    blx     r3
    movs    r5, r0                  @ keep its return value
    ldr     r4, [r4, #BATTLE_DATA_OFF]
    ldr     r0, =bt_system
    str     r4, [r0]

    @ Draw here rather than from the main-loop hook, because here we are AFTER
    @ the battle app has run for this frame - so whatever it printed into the
    @ message window is already down, and our labels go on top of it instead of
    @ under it. That is failure class 4 in docs/AUDIT.md, the one that cost the
    @ PC box a hold.
    cmp     r4, #0
    beq     45f

    bl      OneScreen_BattleMenuId
    push    {r0}
    subs    r1, r0, #BATTLE_MENU_ROOT_LO
    cmp     r1, #(BATTLE_MENU_ROOT_HI - BATTLE_MENU_ROOT_LO)
    bhi     43f                     @ only learn while the root menu is up
    ldr     r1, =BATTLE_INPUT_OFF
    ldr     r0, [r4, r1]
    cmp     r0, #0
    beq     43f
    bl      OneScreen_BattleLearn
43: pop     {r0}
    bl      OneScreen_BattleDraw
45: movs    r0, r5
    pop     {r4, r5, pc}
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
@ void OneScreen_OakDraw(int code) - put a prompt in Oak's dialog box, or pass a
@ negative code to take it down. Redraws only on a change: Oak's text printer
@ writes this window when the question appears and then leaves it alone, so
@ unlike the battle box there is nothing here to fight for it every frame.
    .thumb_func
OneScreen_OakDraw:
    push    {r4, lr}
    ldr     r4, =oak_drawn
    ldr     r1, [r4]
    cmp     r0, #0
    bge     68f
    adds    r0, r1, #1
    beq     69f                     @ already down
    lsrs    r0, r1, #4              @ the set that is up - the gender box is ten
    movs    r2, #0                  @ tiles wide and the yes/no one three, so
    mvns    r2, r2                  @ wiping the wrong one leaves labels behind
    str     r2, [r4]
    bl      OneScreen_BattleWipe
    bl      OneScreen_BattleMenu
    b       69f
68: str     r0, [r4]                @ redraw every frame - Oak repaints this window
    bl      OneScreen_BattleMenu    @ as he builds each state, and a draw-once
                                    @ would simply be painted over
69: pop     {r4, pc}
    .align  2
    .pool

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
    ldr     r0, =oak_data
    str     r4, [r0]
    ldr     r0, [r4, #OAK_STATE_OFF]
    ldr     r1, =oak_state
    str     r0, [r1]


    @ The three prompts that take input get drawn on Oak's own screen instead of
    @ handing the screen over. Gender picks between two symbols, the two
    @ confirmations between yes and no.
    cmp     r0, #OAK_GENDER_PICK
    beq     64f
    cmp     r0, #OAK_CONFIRM_GENDER
    beq     65f
    cmp     r0, #OAK_CONFIRM_NAME
    beq     65f

    @ Lead-in states: pre-wipe the box the prompt is about to use.
    movs    r1, r0
    subs    r1, #OAK_GENDER_PRE_LO
    cmp     r1, #(OAK_GENDER_PRE_HI - OAK_GENDER_PRE_LO)
    bls     73f
    movs    r1, r0
    subs    r1, #OAK_CONFIRM_PRE_LO
    cmp     r1, #(OAK_CONFIRM_PRE_HI - OAK_CONFIRM_PRE_LO)
    bls     73f                     @ gender box: wider, and still showing
                                    @ GARCON/FILLE that must be cleared
    movs    r1, r0
    subs    r1, #OAK_NAME_PRE_LO
    cmp     r1, #(OAK_NAME_PRE_HI - OAK_NAME_PRE_LO)
    bls     74f

    @ Not a prompt: hold the narrow box's own all-paper image over the corner the
    @ icon occupies. Text never reaches those three tiles - it would collide with
    @ the icon if it did - so this is safe even under Oak's longest lines, and it
    @ covers the case where the icon turns out to be tiles rather than an object.
    push    {r0}
    movs    r0, #LABEL_GEO_OAK
    bl      OneScreen_BattleWipe
    bl      OneScreen_OakDraw
    pop     {r0}

    @ Then route.
    @
    @ The gender flow no longer hands the screen over at all. It used to swap for
    @ the whole of 62..93 while the three prompts above kept Oak, which flipped
    @ the screen back and forth through the fades and setup states between them.
    @ Only the tutorial menu still swaps: three options of running French text
    @ will not fit beside the question the way two words do.
    cmp     r0, #OAK_TUTORIAL_HI
    bhi     60f
    movs    r0, #1
    b       62f
60: movs    r0, #0                  @ everything else keeps Oak's own screen
62: bl      OneScreen_SetSwap
61: movs    r0, r5
    pop     {r4, r5, pc}

73: movs    r0, #LABEL_GEO_GENDER
    b       75f
74: movs    r0, #LABEL_GEO_OAK
75: bl      OneScreen_BattleWipe
    bl      OneScreen_OakDraw
    movs    r0, #0                  @ Oak keeps the screen through the lead-in
    bl      OneScreen_SetSwap
    movs    r0, r5
    pop     {r4, r5, pc}

64: movs    r0, #(LABEL_GEO_GENDER << 4)
    b       66f
65: movs    r0, #(LABEL_GEO_OAK << 4)
66: push    {r0}
    ldr     r1, =OAK_NUMOPTS_OFF
    ldrb    r1, [r4, r1]
    cmp     r1, #2
    bne     67f                     @ not the two-option menu we expect
    ldr     r1, =OAK_CURSOR_OFF
    ldrb    r1, [r4, r1]
    cmp     r1, #1
    bhi     67f
    pop     {r0}
    adds    r0, r0, r1
    bl      OneScreen_OakDraw
    movs    r0, #0                  @ Oak keeps the screen
    bl      OneScreen_SetSwap
    movs    r0, r5
    pop     {r4, r5, pc}
67: pop     {r0}
    movs    r0, #0
    bl      OneScreen_SetSwap
    movs    r0, r5
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
@ void OneScreen_StartMenu(void)
@ Draw the overworld menu onto the world itself, on GF_BG_LYR_MAIN_3.
@
@ Every other box this patch draws borrows a message window the game has already
@ created, so the tiles are allocated, mapped and palettised and drawing is a
@ memcpy. The overworld has no such window - the world fills the screen - so this
@ is the one place that writes a TILEMAP as well as pixels.
@
@ It needs no display registers touched at all: MAIN_3 is priority 0 and the 3D
@ world is BG0 at priority 1 (initializeSimple3DVramManager, gf_3d_render.c:46),
@ so the panel is already in front. The strips sit at tile 0x90 - clear of the
@ 130 tiles the menu loads for itself at tile 0, and far below the map-name
@ window at 0x197, the only permanently allocated window on this layer.
@
@ They are re-uploaded on every open rather than once, because a script list menu
@ parks its own tiles at 0x3D..0xDD and eats into ours while the menu is shut.
@ 5 KB once per press of X is nothing, and it removes a whole class of bug.
@
@ Highlighting costs no pixels: the selected cell's tilemap entries are written
@ with a different palette number. That is how the game's own menu does it too -
@ ov27_0225B398 reloads a palette rather than moving a cursor sprite - and it is
@ what keeps this affordable, since one finished image per highlighted entry
@ would have been 32 KB against 11 KB of free ITCM.
@ ---------------------------------------------------------------------------
    .global OneScreen_StartMenu
    .thumb_func
OneScreen_StartMenu:
    push    {r4, r5, r6, r7, lr}
    sub     sp, #16
    ldr     r7, =OneScreen_Labels
    ldr     r0, [r7]
    ldr     r1, =LABEL_MAGIC
    cmp     r0, r1
    bne     57f                     @ blob never filled in: draw nothing at all

    @ Every pointer checked. A stale one reaching the IPC FIFO at 0x04100000 is
    @ what hung the ARM9 during the field-prompt attempt, and this walks the same
    @ kind of chain.
    ldr     r0, =cfg_field_sys
    ldr     r0, [r0]
    cmp     r0, #0
    beq     57f
    ldr     r6, [r0]                @ sFieldSysPtr -> FieldSystem
    cmp     r6, #0
    beq     57f
    ldr     r4, [r6, #TASKMAN_OFF]
    cmp     r4, #0
    beq     57f
    ldr     r0, [r4, #TASK_FUNC_OFF]
    ldr     r1, =cfg_start_menu_task
    ldr     r1, [r1]
    cmp     r1, #0
    beq     57f                     @ the patcher could not vouch for the task
    cmp     r0, r1
    bne     57f                     @ something else owns the field right now
    ldr     r4, [r4, #TASK_ENV_OFF] @ -> StartMenuTaskData
    cmp     r4, #0
    beq     57f

    movs    r0, #SM_RECORD_OFF
    adds    r7, r7, r0              @ -> the panel's record
    movs    r0, #SM_CURSOR_OFF      @ 0xD3 is out of reach of ldrb's immediate
    ldrb    r5, [r6, r0]            @ the live cursor

    @ Only the ordinary overworld grid is reproduced. Safari, the Bug Contest and
    @ Pal Park use different ones (ov27_0225CFC8 rows 1-3) that put RETIRE first
    @ and shift everything after it, and the variant lives in the touch overlay's
    @ own struct where this cannot reach. All of them leave RETIRE ENABLED, while
    @ the normal layout always inhibits it (src/start_menu.c:307) - so that bit
    @ separates them. Anywhere else this returns 0 and the caller swaps instead,
    @ which is what the patch always did.
    ldr     r0, =SM_INHIBIT_OFF
    ldr     r0, [r4, r0]
    str     r0, [sp, #8]
    movs    r1, #1
    lsls    r1, r1, #SM_NORMAL_BIT
    tst     r0, r1
    bne     56f
57: b       79f                     @ trampoline: the exit is past a conditional
56:                                 @ branch's 256-byte reach from the checks
    ldr     r0, =sm_drawn
    ldr     r0, [r0]
    cmp     r0, #0
    bne     74f                     @ strips are already in VRAM
    ldr     r0, =OneScreen_Labels
    ldr     r1, [r7, #SM_TILES_OFF]
    adds    r1, r0, r1
    ldr     r2, [r7, #SM_TILES_DEST]
    ldr     r3, [r7, #SM_TILES_BYTES]
72: ldmia   r1!, {r0}
    stmia   r2!, {r0}
    subs    r3, #4
    bne     72b
    ldr     r0, =OneScreen_Labels   @ both palettes at once; the builder keeps
    ldr     r1, [r7, #SM_PAL_OFF]   @ the highlighted one immediately after
    adds    r1, r0, r1
    ldr     r2, [r7, #SM_PAL_DEST]
    movs    r3, #SM_PAL_BYTES
73: ldmia   r1!, {r0}
    stmia   r2!, {r0}
    subs    r3, #4
    bne     73b
    ldr     r0, =sm_drawn
    movs    r1, #1
    str     r1, [r0]

74: ldrb    r0, [r7, #SM_CELL_W]    @ spilled: the inner loops need every register
    str     r0, [sp]
    ldrb    r0, [r7, #SM_CELL_H]
    str     r0, [sp, #4]

    @ The grey border, blitted whole - interior included, since the cells are
    @ drawn over it straight after. Two flat loops beat working out which cells
    @ are edges at runtime.
    ldr     r0, =OneScreen_Labels
    ldr     r1, [r7, #SM_FRAME_OFF]
    adds    r1, r0, r1
    ldr     r2, [r7, #SM_FRAME_BASE]
    movs    r3, #SM_FRAME_ROWS
    ldrb    r0, [r7, r3]
64: cmp     r0, #0
    beq     63f
    push    {r0, r2}
    movs    r3, #SM_FRAME_COLS
    ldrb    r3, [r7, r3]
62: ldrh    r0, [r1]
    strh    r0, [r2]
    adds    r1, #2
    adds    r2, #2
    subs    r3, #1
    bne     62b
    pop     {r0, r2}
    movs    r3, #SM_MAP_STRIDE
    adds    r2, r2, r3              @ down one tilemap row
    subs    r0, #1
    b       64b

63: movs    r6, #0                  @ cell index
    movs    r0, #0
    str     r0, [sp, #12]           @ enabled cells seen so far
75: ldrb    r0, [r7, #SM_N_CELLS]
    cmp     r6, r0
    bhs     59f

    @ What belongs in this cell, and have you earned it? A cell you have not is
    @ left EMPTY rather than closing the list up, because that is what the touch
    @ menu does - the slots are fixed and missing entries leave gaps.
    ldrb    r3, [r7, #SM_BLANK]     @ assume empty
    movs    r4, #0                  @ and not highlighted
    movs    r0, #SM_CELL_LABEL
    adds    r0, r7, r0
    ldrb    r0, [r0, r6]
    cmp     r0, #0xFF
    beq     77f                     @ nothing ever lives here
    movs    r1, #SM_CELL_BIT
    adds    r1, r7, r1
    ldrb    r1, [r1, r6]
    cmp     r1, #0xFF
    beq     76f                     @ never inhibited
    ldr     r2, [sp, #8]
    lsrs    r2, r2, r1
    movs    r1, #1
    ands    r2, r1
    cmp     r2, #0
    bne     77f                     @ not earned yet: leave the gap
76: movs    r3, r0                  @ draw this label

    @ The cursor counts only the entries you have, so its index is this cell's
    @ position among the enabled ones - not the cell number.
    ldr     r0, [sp, #12]
    adds    r1, r0, #1
    str     r1, [sp, #12]
    cmp     r0, r5
    bne     77f
    movs    r4, #1

77: ldrb    r0, [r7, #SM_STRIP_TILES]
    muls    r3, r0
    ldrh    r0, [r7, #SM_BASE_TILE]
    adds    r3, r3, r0              @ first tile of that strip

    ldrb    r2, [r7, #SM_PAL_NORM]
    cmp     r4, #0
    beq     78f
    ldrb    r2, [r7, #SM_PAL_HI]
78: lsls    r2, r2, #12
    orrs    r3, r2                  @ a finished tilemap entry

    movs    r0, #0                  @ row within the cell
70: ldr     r2, [sp, #4]
    cmp     r0, r2
    bhs     68f
    ldr     r2, [sp, #4]
    muls    r2, r6
    adds    r2, r2, r0
    lsls    r2, r2, #2
    movs    r1, #SM_ROWS_OFF
    adds    r1, r7, r1
    ldr     r1, [r1, r2]            @ absolute tilemap address for this row
    ldr     r2, [sp]                @ cell_w, counted down
71: strh    r3, [r1]
    adds    r1, #2
    adds    r3, #1                  @ a strip's tiles are consecutive, so the
    subs    r2, #1                  @ entry simply walks forward across rows too
    bne     71b
    adds    r0, #1
    b       70b
68: adds    r6, #1
    b       75b

59: movs    r0, #1                  @ drawn: the caller leaves the screen alone
    b       58f
79: movs    r0, #0                  @ not a layout we can reproduce
58: add     sp, #16
    pop     {r4, r5, r6, r7, pc}
    .align  2
    .pool

@ ---------------------------------------------------------------------------
@ void OneScreen_StartMenuWipe(void)
@ Take the panel down and forget the upload, so the next open re-sends the
@ strips. The game clears this whole layer when the menu tears down properly
@ (sub_0203C38C), but not on every path that ends it - Dig and Escape Rope jump
@ straight to an exit task - so the panel clears itself rather than trusting it.
@ ---------------------------------------------------------------------------
    .global OneScreen_StartMenuWipe
    .thumb_func
OneScreen_StartMenuWipe:
    push    {r4, r5, r6, r7, lr}
    ldr     r7, =OneScreen_Labels
    ldr     r0, [r7]
    ldr     r1, =LABEL_MAGIC
    cmp     r0, r1
    bne     67f
    ldr     r0, =sm_drawn
    ldr     r1, [r0]
    cmp     r1, #0
    beq     67f                     @ nothing of ours is on screen
    movs    r1, #0
    str     r1, [r0]
    movs    r0, #SM_RECORD_OFF
    adds    r7, r7, r0
    ldr     r1, [r7, #SM_FRAME_BASE]    @ the border's rect covers the cells too
    movs    r0, #SM_FRAME_ROWS
    ldrb    r4, [r7, r0]
66: cmp     r4, #0
    beq     67f
    movs    r0, #SM_FRAME_COLS
    ldrb    r2, [r7, r0]
    movs    r5, r1                  @ keep the row start
    movs    r3, #0
65: strh    r3, [r1]
    adds    r1, #2
    subs    r2, #1
    bne     65b
    movs    r1, r5
    movs    r3, #SM_MAP_STRIDE
    adds    r1, r1, r3
    subs    r4, #1
    b       66b
67: pop     {r4, r5, r6, r7, pc}
    .align  2
    .pool

@ int OneScreen_MainRamRange(void *ptr, u32 last_word_off)
@ Accept only aligned pointers whose last word is still in the DS's 4 MB main
@ RAM. Every link in the field-controller chain passes through here before it is
@ read: a non-null stale pointer once reached the IPC FIFO and hung ARM9.
    .thumb_func
OneScreen_MainRamRange:
    movs    r2, #3
    tst     r0, r2
    bne     40f
    ldr     r2, =0x02000000
    cmp     r0, r2
    blo     40f
    adds    r1, r0, r1
    ldr     r2, =0x02400000
    cmp     r1, r2
    bhs     40f
    movs    r0, #1
    bx      lr
40: movs    r0, #0
    bx      lr
    .align  2
    .pool

@ Classify the stable overlay-27 mode-3 controller behind FieldSystem.
@   0 invalid (fail closed to the native lower screen)
@   1 transition/setup/idle/binary teardown (keep the world)
@   2 binary prompt, Yes selected
@   3 binary prompt, No selected
@   4 non-mirrored native states 7..11 (lists at 7..10; cleanup at 11)
    .thumb_func
OneScreen_FieldMode3:
    push    {r3, r4, r5, r6, r7, lr}
    movs    r4, r0                  @ FieldSystem

    movs    r1, #FIELD_TOUCH_TASK_OFF
    bl      OneScreen_MainRamRange
    cmp     r0, #0
    beq     49f
    movs    r0, #FIELD_TOUCH_TASK_OFF
    ldr     r5, [r4, r0]
    movs    r0, r5
    movs    r1, #SYS_TASK_DATA_OFF
    bl      OneScreen_MainRamRange
    cmp     r0, #0
    beq     49f
    ldr     r6, [r5, #SYS_TASK_DATA_OFF]
    movs    r0, r6
    movs    r1, #FIELD_OUTER_LAST_OFF
    bl      OneScreen_MainRamRange
    cmp     r0, #0
    beq     49f
    ldr     r0, [r6, #FIELD_OUTER_FS_OFF]
    cmp     r0, r4
    bne     49f                     @ not this FieldSystem's manager

    ldrb    r0, [r6, #FIELD_OUTER_STATE_OFF]
    cmp     r0, #FIELD_OUTER_IDLE
    beq     43f

    @ While the outer manager changes modes, its child can still be the outgoing
    @ task. Validate the transition but deliberately do not follow that pointer.
    cmp     r0, #FIELD_OUTER_TRANS_LO
    blo     49f
    cmp     r0, #FIELD_OUTER_TRANS_HI
    bhi     49f
    ldrb    r0, [r6, #FIELD_OUTER_NEXT_OFF]
    cmp     r0, #FIELD_TOUCH_MODE
    bne     49f
    movs    r0, #1
    b       48f

43: ldrb    r0, [r6, #FIELD_OUTER_MODE_OFF]
    cmp     r0, #FIELD_TOUCH_MODE
    bne     49f
    ldr     r5, [r6, #FIELD_OUTER_CHILD_OFF]
    movs    r0, r5
    movs    r1, #SYS_TASK_DATA_OFF
    bl      OneScreen_MainRamRange
    cmp     r0, #0
    beq     49f
    ldr     r7, [r5, #SYS_TASK_DATA_OFF]
    movs    r0, r7
    ldr     r1, =FIELD_CHILD_CHOICE_OFF
    bl      OneScreen_MainRamRange
    cmp     r0, #0
    beq     49f
    ldr     r0, [r7, #FIELD_CHILD_FS_OFF]
    cmp     r0, r4
    bne     49f                     @ stale controller from another field

    ldr     r5, [r7, #FIELD_CHILD_STATE_OFF]
    cmp     r5, #FIELD_CHILD_STATE_HI
    bhi     49f
    cmp     r5, #FIELD_CHILD_LIST_LO
    blo     44f
    movs    r0, #4                  @ native list/cleanup state
    b       48f
44: cmp     r5, #FIELD_CHILD_BINARY_LO
    blo     47f                     @ setup/idle
    cmp     r5, #FIELD_CHILD_BINARY_DONE
    beq     47f                     @ result delivered
    cmp     r5, #FIELD_CHILD_BINARY_LO
    bne     45f
    movs    r0, #2                  @ state 3 initializes Yes
    b       48f
45: ldr     r1, =FIELD_CHILD_CHOICE_OFF
    ldr     r0, [r7, r1]
    cmp     r0, #1
    bhi     49f
    adds    r0, #2                  @ 0/1 -> Yes/No classification 2/3
    b       48f
47: movs    r0, #1
48: pop     {r3, r4, r5, r6, r7, pc}
49: movs    r0, #0
    b       48b
    .align  2
    .pool

@ Wipe the field labels once, and only while the field app still owns MAIN_3.
@ `field_yn_drawn` is reset without a VRAM write on app exit below.
    .thumb_func
OneScreen_FieldYesNoWipe:
    push    {r3, lr}
    ldr     r1, =field_yn_drawn
    ldr     r0, [r1]
    adds    r0, #1
    beq     51f                     @ already absent
    movs    r0, #0
    mvns    r0, r0
    str     r0, [r1]
    movs    r0, #LABEL_GEO_FIELD
    bl      OneScreen_BattleWipe
    bl      OneScreen_BattleMenu
51: pop     {r3, pc}
    .align  2
    .pool

@ ---------------------------------------------------------------------------
@ int OneScreen_ScriptMenu(void)
@ Route field-owned lower modes. Binary mode-3 prompts are mirrored into the
@ world's MAIN_3 dialog; real lists and every other mode retain native routing.
@ ---------------------------------------------------------------------------
    .global OneScreen_ScriptMenu
    .thumb_func
OneScreen_ScriptMenu:
    push    {r3, r4, r5, lr}
    ldr     r0, =cfg_field_sys
    ldr     r0, [r0]
    cmp     r0, #0
    beq     59f
    ldr     r4, [r0]                @ FieldSystem through sFieldSysPtr
    cmp     r4, #0
    beq     59f                     @ no field system yet (boot, menus)
    movs    r0, r4
    movs    r1, #FIELD_TOUCH_TASK_OFF
    bl      OneScreen_MainRamRange
    cmp     r0, #0
    beq     59f                     @ do not dereference a stale FieldSystem
    ldr     r5, [r4, #FIELD_MENU_OFF]
    cmp     r5, #0
    beq     57f
    cmp     r5, #FIELD_TOUCH_MODE
    bne     56f                     @ other field modes show their native UI

    movs    r0, r4
    bl      OneScreen_FieldMode3
    movs    r5, r0
    cmp     r5, #0
    beq     56f                     @ invalid chain: fail closed
    cmp     r5, #4
    beq     56f                     @ native list/cleanup state
    cmp     r5, #1
    beq     53f                     @ transition/setup/teardown

    @ Binary selection 2/3 -> image index 0/1. A missing or old blob also fails
    @ closed, so an unrenderable prompt always leaves the native choices visible.
    ldr     r0, =OneScreen_Labels
    ldr     r1, [r0]
    ldr     r2, =LABEL_MAGIC
    cmp     r1, r2
    bne     56f
    ldrb    r1, [r0, #5]
    cmp     r1, #LABEL_GEO_COUNT
    blo     56f
    subs    r5, #2
    ldr     r1, =field_yn_drawn
    str     r5, [r1]
    movs    r0, r5
    adds    r0, #(LABEL_GEO_FIELD << 4)
    bl      OneScreen_BattleMenu    @ redraw after the game's message work
    b       54f

53: bl      OneScreen_FieldYesNoWipe
54: ldr     r1, =script_menu
    movs    r0, #1
    str     r0, [r1]
    movs    r0, #0                  @ engine A: world + dialog on upper LCD
    bl      OneScreen_SetSwap
    movs    r0, #1
    pop     {r3, r4, r5, pc}

56: bl      OneScreen_FieldYesNoWipe
    ldr     r1, =script_menu
    movs    r0, #1
    str     r0, [r1]
    bl      OneScreen_SetSwap       @ engine B: native list/fallback on upper LCD
    movs    r0, #1
    pop     {r3, r4, r5, pc}

57: bl      OneScreen_FieldYesNoWipe
    ldr     r4, =script_menu
    ldr     r0, [r4]
    cmp     r0, #0
    beq     59f                     @ it was never ours
    movs    r0, #0                  @ menu closed: put the world back
    str     r0, [r4]
    bl      OneScreen_SetSwap
59: movs    r0, #0
    pop     {r3, r4, r5, pc}
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
    ldr     r0, =bt_manual          @ stop the battle logic re-asserting, so a
    movs    r1, #1                  @ manual override sticks until the menu you
    str     r1, [r0]                @ are on changes, or the phase does

10: ldr     r5, =menu_swapped
    ldr     r0, =cfg_app_callback
    ldr     r0, [r0]
    ldr     r0, [r0]
    ldr     r1, =cfg_field_callback
    ldr     r1, [r1]
    cmp     r0, r1
    beq     11f
    @ Not the overworld. KEEP the latch, so a trip into the bag/party/Pokédex and
    @ back leaves the menu drawn where you left it. Drop the latch only in
    @ battle, where the battle logic owns the screens.
    @
    @ Forget the upload, though: those apps reuse this layer's VRAM, so the
    @ strips will not have survived. Clearing the flag makes the next draw send
    @ them again rather than pointing the tilemap at whatever is there now.
    ldr     r0, =sm_drawn
    movs    r1, #0
    str     r1, [r0]
    @ An app may reuse MAIN_3 immediately. Forget field labels without wiping
    @ here; the field-only path above is the sole safe place to touch that VRAM.
    ldr     r0, =field_yn_drawn
    movs    r1, #0
    mvns    r1, r1
    str     r1, [r0]
    ldr     r0, =cfg_app_callback
    ldr     r0, [r0]
    ldr     r0, [r0]
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
    cmp     r0, #0
    bne     19f                     @ opening: the draw below picks it up
    bl      OneScreen_StartMenuWipe @ closing: take the panel off the world
    movs    r0, #0                  @ and undo the swap, if this was a grid we
    bl      OneScreen_SetSwap       @ could not draw and swapped for instead
    b       19f

12: movs    r0, r4
    movs    r1, #KEY_B
    ands    r0, r1
    cmp     r0, #0
    beq     15f
    ldr     r0, [r5]
    cmp     r0, #0
    beq     15f                     @ no menu of ours is up: leave B alone
    movs    r0, #0
    str     r0, [r5]
    bl      OneScreen_StartMenuWipe @ B closed the menu
    movs    r0, #0
    bl      OneScreen_SetSwap
    b       19f

    @ Keep the panel on the world while the menu is open. Drawn every frame, not
    @ once: the field redraws underneath it, and coming back from a sub-app
    @ rebuilds the menu task entirely.
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
    bl      OneScreen_StartMenuWipe
    ldr     r1, =field_restore
    movs    r0, #FIELD_RESTORE_FRAMES
    str     r0, [r1]
    b       16f

14: ldr     r1, =field_restore      @ the menu is up: drop any pending restore so
    movs    r0, #0                  @ it cannot fire underneath the panel
    str     r0, [r1]
    bl      OneScreen_StartMenu     @ draw it onto the world; no swap at all
    cmp     r0, #0
    bne     19f
    movs    r0, #1                  @ ...unless it is a grid we cannot reproduce
    bl      OneScreen_SetSwap       @ (Safari, the Bug Contest): swap, as before
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

@ ---------------------------------------------------------------------------
@ The command labels, rasterised from the ROM's own strings and font at patch
@ time by onescreen/labels.py and written in here by inject.fill_labels. Kept
@ last in the payload so adding to it never moves any code.
@
@ A 272-byte header holds five geometry records plus the start-menu record. Four
@ unique localized 4bpp image sets follow it; the field-dialog geometry aliases
@ the battle Yes/No pixels. The hook reads the recorded geometry rather than
@ repeating it, so the layout cannot drift away from the rasteriser's.
@
@ An unfilled blob reads as zeroes, whose magic does not match, and
@ OneScreen_BattleMenu draws nothing at all rather than garbage.
@ ---------------------------------------------------------------------------
    .align  2
    .global OneScreen_Labels
OneScreen_Labels:
    .space  LABEL_BLOB_SIZE
