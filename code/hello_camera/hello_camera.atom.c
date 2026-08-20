#ifdef INTELLISENSE_DIRECTIVES
#	pragma once
#		include "duffle/gen/macs.h"
#		include "duffle/gen/offsets.h"
#	include "duffle/dsl.atom.h"
#	include "duffle/lottes_tape.h"
#	include "duffle/mips.h"
#	include "duffle/gte.h"
#	include "duffle/gp.h"
#	include "duffle/pad.h"
#	include "duffle/word_count.metadata.h"
#	include "duffle/psyq.h"
#	include "duffle/math.atom.h"
#	include "duffle/mips.atom.c"
#	include "duffle/gte.atom.c"
#	include "duffle/gp.atom.c"
#	include "duffle/psyq.atom.c"
#		include "gen/offsets.h"
#		include "gen/macs.h"
#		include "gen/auto_reg.h"
#	include "hello_camera.h"
#endif

ATOM_FILE_DEBUGGER_LINE_MARKER(hello_joypad_atom_c);

#pragma region MACs (Mips Atom components)

FI_ Slice_MipsCode ac_put_disp_env(AtomBuilder_R ab, U4 reg_transfer, U4 reg_base, U2 port)
MipsAtomComp_Proc_(ab, {
	// Emits 5 GP0 commands for buffer 0 (display_area = (0,0,320,240)).
	// Sequence per libpsyx PutDispEnv: DrawArea TL → DrawArea BR → Mask → DrawArea TL → DrawArea BR
	mac_gcmd_push(gp0_word_draw_area_top_left_origin,      reg_transfer, reg_base, port),
	mac_gcmd_push(gp0_word_draw_area_bottom_right_320x240, reg_transfer, reg_base, port),
	mac_gcmd_push(gp0_word_set_mask_bit(),                 reg_transfer, reg_base, port),
	mac_gcmd_push(gp0_word_draw_area_top_left_origin,      reg_transfer, reg_base, port),
	mac_gcmd_push(gp0_word_draw_area_bottom_right_320x240, reg_transfer, reg_base, port),
})

I_ Slice_MipsCode ac_put_draw_env(AtomBuilder_R ab, U4 reg_transfer, U4 reg_base, U2 port)
MipsAtomComp_Proc_(ab, {
	/*
	* ORIGIN: each code word corresponds to the EXACT value libpsyx's PutDrawEnv function would compute for the same DrawEnv settings.
	* References:
	*   - libpsyx source: `toolchain/psyq-4_7/lib/libgpu.a` (binary, function `PutDrawEnv`)
	*   - PSX-SPX doc:     https://problemkaputt.de/psx-spx.htm#gputdrawingcommands
	*   - PSYQ SDK:        `setdrawenv` / `makelongdr_env` source
	*   - NOCASH PSX spec: §"GP0(E1h) Draw Mode setting" through §"DR_ENV"
	*
	* The 16-word format is documented in the PSYQ SDK manual and on NOCASH's PSX-spec.txt. The libpsyx reference is at:
	*   ./toolchain/psyq-4_7/lib/libgpu.a
	*   (binary; the PutDrawEnv implementation builds the 16-word DR_ENV from the user's DRAWENV struct and emits it via GP0 GPU commands.)
	*
	* Word indices (libpsyx PutDrawEnv / SetDrawEnv order):
	*   tag          = (length << 24) | addr                — 16-word packet (1 tag + 15 code)
	*   code[0]      = DrawMode (dfe=1, dtd=0, tpage=0)     — must come first per libpsyx
	*   code[1]      = TextureWindow (tw=(0,0))             — bare-cmd word; GPU uses current state
	*   code[2]      = DrawArea top-left (clip.x=0, clip.y=240)
	*   code[3]      = DrawArea bottom-right (clip.x+w=320, clip.y+h=480)
	*   code[4]      = DrawOffset (ofs=(0,0))               — bare-cmd word
	*   code[5]      = Mask (dtd=0, dfe=1, isbg=1)          — 0xE6 cmd + isbg bit
	*   code[6]      = Initial-bg-color (isbg=1, r=7, g=7, b=7)
	*   code[7]      = DrawMode (isbg=1, tpage=0)           — re-asserts DrawMode with isbg
	*   code[8..10]  = padding (NOP)                        — 3 words to fill the packet
	*   code[11..12] = TextureWindow bottom-right           — defaults to (0,0,0,0)
	*   code[13..14] = padding (NOP)                        — completes the 16-word packet
	*/
	mac_gcmd_push(gp0_dr_env_tag,                            reg_transfer, reg_base, port), /* tag (length=15 << 24, addr=0) — packet header for the DR_ENV sequence. The GPU needs this to recognize the next 15 words as a DR_ENV packet and trigger the isbg auto-clear. */
	mac_gcmd_push(gp0_word_draw_mode_drawing_allowed,        reg_transfer, reg_base, port), /* code[0]  DrawMode (dfe=1, dtd=0, tpage=0) */
	mac_gcmd_push(gp0_word_set_texture_window(),             reg_transfer, reg_base, port), /* code[1]  TextureWindow (tw=(0,0)) */
	mac_gcmd_push(enc_gp0_draw_area_tl_word(0, ScreenRes_Y), reg_transfer, reg_base, port), /* code[2]  DrawArea top-left (clip.x=0, clip.y=ScreenRes_Y=240) */
	mac_gcmd_push(gp0_word_draw_area_bottom_right_320x240,   reg_transfer, reg_base, port), /* code[3]  DrawArea bottom-right (clip.x+w=320, clip.y+h=480) */

	mac_gcmd_push(gp0_word_set_draw_offset(),               reg_transfer, reg_base, port), /* code[4]  DrawOffset (ofs=(0,0)) — bare-cmd word; the GPU uses the current state machine. */
	mac_gcmd_push(gp0_word_dr_env_mask(),                   reg_transfer, reg_base, port), /* code[5]  Mask (dtd=0, dfe=1, isbg=1) — 0xE6 cmd + isbg bit. */
	mac_gcmd_push(gp0_word_dr_env_bg_color_cmd(1, 7, 7, 7), reg_transfer, reg_base, port), /* code[6]  Initial-bg-color + auto-clear (isbg=1, r=7, g=7, b=7). */
	mac_gcmd_push(gp0_word_dr_env_draw_mode(1),             reg_transfer, reg_base, port), /* code[7]  Re-assert DrawMode with isbg=1 (isbg-flag set; the 0xE1 cmd byte plus isbg only). */

	/* code[8..10]  Padding (NOP — GPU discards; the DR_ENV requires 16 words total). */
	mac_gcmd_push(gp0_word_nop(), reg_transfer, reg_base, port),
	mac_gcmd_push(gp0_word_nop(), reg_transfer, reg_base, port),
	mac_gcmd_push(gp0_word_nop(), reg_transfer, reg_base, port),

	/* code[11..12]  TextureWindow bottom-right (tw.x+tw.w=0, tw.y+tw.h=0) — libpsyx emits twice. */
	mac_gcmd_push(gp0_word_set_texture_window(), reg_transfer, reg_base, port),
	mac_gcmd_push(gp0_word_set_texture_window(), reg_transfer, reg_base, port),

	/* code[13..14]  Padding (NOP) — completes the 16-word packet. */
	mac_gcmd_push(gp0_word_nop(), reg_transfer, reg_base, port),
	mac_gcmd_push(gp0_word_nop(), reg_transfer, reg_base, port),
})

#pragma endregion MACs

#pragma region Atom Procs

#pragma region resolve_look_at
/* ─── resolve_look_at bundle chain atoms ──────────────────────────── */

typedef AtomBundle_(resolve_look_at) { MipsAtom
	*input_and_sub,
	*normalize_fwd_uz,
	*cross_to_right,
	*normalize_right_ux,
	*cross_to_up,
	*normalize_up_uy,
	*populate_mt3s4s2;
};

typedef Struct_(ResolveLookAtScratch) {
	V3_S4 fwd;
	V3_S4 uz;
	V3_S4 right;
	V3_S4 ux;
	V3_S4 up;
	V3_S4 uy;
	P3_S4 eye;
	P3_S4 target;
	V3_S4 up_in;
};

typedef Struct_(Binds_ResolveLookAtSub) {
	P3_S4* target;
	P3_S4* eye;
	V3_S4* up_in;
};
typedef Struct_(RegUse_resolve_look_at_input_and_sub) {
	Reg target_ptr;
	Reg eye_ptr;
	Reg up_in_ptr;
	union { Reg_(V3_S4) r012, up_in,  eye; };
	union { Reg_(V3_S4) r345, target, fwd; };
};
/* Atom 0 in the bundle: input_and_sub. Stages C-side inputs into the scratchpad and computes fwd = target - eye. */
internal MipsAtom* AtomBundleEntry_(resolve_look_at,input_and_sub)(AtomArena_R aa, RegUse_resolve_look_at_input_and_sub r)
atom_info(atom_bind(Binds_ResolveLookAtSub)) MipsAtom_Proc_(aa, {
	load_word(r.target_ptr, R_TapePtr, O_(Binds_ResolveLookAtSub,target)),
	load_word(r.eye_ptr,    R_TapePtr, O_(Binds_ResolveLookAtSub,eye)),
	load_word(r.up_in_ptr,  R_TapePtr, O_(Binds_ResolveLookAtSub,up_in)),
	LdSlot_ add_ui_self(R_TapePtr, S_(Binds_ResolveLookAtSub)),

	/* Stage up_in.x/y/z into the scratchpad. R_ScratchBase = R_SP = 0x1F800000. */
	mac_load_v3s4( r.up_in, r.up_in_ptr, 0), LdSlot_
	mac_store_v3s4(r.up_in, R_ScratchBase, O_(ResolveLookAtScratch,up_in)),

	// Stage eye.x/y/z into the scratchpad (atom 6 reads these for the translation column).
	mac_load_v3s4( r.eye, r.eye_ptr, 0), LdSlot_
	mac_store_v3s4(r.eye, R_ScratchBase, O_(ResolveLookAtScratch,eye)),

	/* Compute fwd = target - eye. */
	mac_load_v3s4(    r.target, r.target_ptr, 0), LdSlot_
	mac_sub_v3s4_self(r.fwd, r.eye),
	mac_store_v3s4(   r.fwd, R_ScratchBase, O_(ResolveLookAtScratch,fwd)),

	mac_yield()
})

typedef Struct_(Binds_ResolveLookAt_PopulateMT3S4S2) {
	U4 look_at;  /* MT3_S2S4* — destination matrix address */
};
typedef Struct_(RegUse_resolve_look_at_populate_mt3s4s2) {
	Reg         look_at;
	Reg         eye;            /* matrix_vector phase: load -eye */
	Reg_(V3_S4) row;            /* populate phase: load ux/uy/uz */
	union { Reg r0, ux, vx; }; /* populate addr → matrix_vector v_x */
	union { Reg r1, uy, vy; }; /* populate uy   → matrix_vector v_y */
	union { Reg r2, uz, vz; }; /* populate uz   → matrix_vector v_z */
};
/* write look_at->m[][] from ux/uy/uz as packed S2 (populate),
 * ctc2 RT chain into C2[0..4] (matrix_vector), MVMVA RT*(-eye)>>12, store off
 * directly to look_at->t[] (trans_matrix).
 *
 * C11 ApplyMatrixLV semantics (gte.atom.c ac_apply_matrix_lv; libgte reference):
 *   1. ctc2 RT matrix (5 ctc2s to C2[0..4])
 *   2. lw -eye from memory
 *   3. S15 decomposition (eliminated here — the fused body takes the >>12 path
 *      directly via mtc2 IR + MVMVA pass2, matching the libgte canonical output)
 *   4. mtc2 to IR1/2/3, nop2, MVMVA pass2 (sf=1, mx=0, v=3, cv=3)
 *   5. mfc2 MACs → off
 *   6. store off to look_at->t[] (skip scratch.eye intermediate)
 */
internal MipsAtom* AtomBundleEntry_(resolve_look_at,populate_mt3s4s2)(AtomArena_R aa, RegUse_resolve_look_at_populate_mt3s4s2 r)
atom_info(atom_bind(Binds_ResolveLookAt_PopulateMT3S4S2)) MipsAtom_Proc_(aa, {
	/* --- Tape pop: look_at pointer --- */
	load_word(r.look_at, R_TapePtr, O_(Binds_ResolveLookAt_PopulateMT3S4S2,look_at)),
	LdSlot_ add_ui_self(R_TapePtr, S_(Binds_ResolveLookAt_PopulateMT3S4S2)),

	add_si(r.ux,  R_ScratchBase, O_(ResolveLookAtScratch, ux)), LdSlot_
	add_si(r.uy,  R_ScratchBase, O_(ResolveLookAtScratch, uy)),
	add_si(r.uz,  R_ScratchBase, O_(ResolveLookAtScratch, uz)),
	add_si(r.eye, R_ScratchBase, O_(ResolveLookAtScratch, eye)),

	/* write look_at->m[][] from ux/uy/uz as packed S2 */
	mac_load_v3s4(r.row, r.ux, 0), LdSlot_ mac_store_v3s2(r.row, r.look_at, O_(MT3_S2S4, m[0])),
	mac_load_v3s4(r.row, r.uy, 0), LdSlot_ mac_store_v3s2(r.row, r.look_at, O_(MT3_S2S4, m[1])),
	mac_load_v3s4(r.row, r.uz, 0), LdSlot_ mac_store_v3s2(r.row, r.look_at, O_(MT3_S2S4, m[2])),

	/* ctc2 RT chain + MVMVA RT * (-eye) >> 12 */
	/*   C2[0] = (RT12<<16)|RT11  ← ctc2 RT11 from m[0][0..1]
	 *   C2[1] = (RT21<<16)|RT13  ← ctc2 RT12 from m[0][2..3]
	 *   C2[2] = (RT23<<16)|RT22  ← ctc2 RT13 from m[1][1..2]
	 *   C2[3] = (RT32<<16)|RT31  ← ctc2 RT21 from m[2][0..1]
	 *   C2[4] = (RT33<<16)|junk  ← ctc2 RT22 from m[2][2] (half) */
	load_word(  r.vx, r.look_at, O_(MT3_S2S4, m[0][0])), /* RT11|RT12 */ LdSlot_
	load_word(  r.vy, r.look_at, O_(MT3_S2S4, m[0][2])), /* RT13|RT21 */ LdSlot_ gte_mv_to_ctrl_r(r.vx, gte_cr_RT11),
	load_word(  r.vz, r.look_at, O_(MT3_S2S4, m[1][1])), /* RT22|RT23 */ LdSlot_ gte_mv_to_ctrl_r(r.vy, gte_cr_RT12),
	load_word(  r.vx, r.look_at, O_(MT3_S2S4, m[2][0])), /* RT31|RT32 */ LdSlot_ gte_mv_to_ctrl_r(r.vz, gte_cr_RT13),
	load_half_u(r.vy, r.look_at, O_(MT3_S2S4, m[2][2])), /* RT33 */      LdSlot_ gte_mv_to_ctrl_r(r.vx, gte_cr_RT21),

	GteDelay_ mac_load_word_v3(r.vx, r.vy, r.vz, r.eye, 0), LdSlot_ 
	mac_sub_s_v3(r.vx, r.vy, r.vz, R_0, R_0, R_0, r.vx, r.vy, r.vz),

	gte_mv_to_data_r(r.vx, C2_IR1),
	gte_mv_to_data_r(r.vy, C2_IR2),
	gte_mv_to_data_r(r.vz, C2_IR3),
	GteDelay_ nop2,

	/* MVMVA pass 2 — C11 ApplyMatrixLV command. sf=1, mx=0 (RT), v=3 (IR), cv=3. Reads RT × IR >> 12. */
	gte_cmdw_mvmva_c11_pass2,                        GteDelay_ load_word(R_AtomJmp, R_TapePtr, 0),            // ac_yield: word 1
	mac_gte_mv_from_data_r_mac123(r.vx, r.vy, r.vz), GteDelay_ add_ui_self(         R_TapePtr, S_(MipsCode)), // ac_yield: word 2

	/* store off directly to look_at->t[] (skip scratch.eye intermediate) */
	mac_store_word_v3(r.vx, r.vy, r.vz, r.look_at, O_(MT3_S2S4, t)),

	jump_reg(R_AtomJmp), BdSlot_ nop, // ac_yield: word 3-4
})
#pragma endregion resolve_look_at

#pragma endregion Atom Procs

#pragma region Baked Atoms

enum {
	R_ScreenX   = R_T5 atom_reg atom_type(U2),
	R_ScreenY   = R_T6 atom_reg atom_type(U2),
	R_ScreenBuf = R_T7 atom_reg, /* Caller-pinned: & smem.screen_buf */
#define R_ScreenBuf_Code R_T7_Code
};
//screen_env_init. Mirrors the libpsyx's SetDefDispEnv + SetDefDrawEnv + the manual enable_auto_clear / initial_bg_color writes.
internal MipsAtom_(screen_env_init) atom_info(atom_phase(screen_init)
,	atom_reads(R_T0, R_ScreenX, R_ScreenY, R_ScreenBuf)
, atom_writes(R_T0, R_ScreenX, R_ScreenY)
) {
	/* display[0] = (0, 0, 320, 240); rest of struct zeroed. */
	add_ui(R_ScreenX, R_0, ScreenRes_X), add_ui(R_ScreenY, R_0, ScreenRes_Y),
	mac_store_v2s2(R_ScreenX, R_ScreenY, R_ScreenBuf, O_(DisplayEnv,display_area.width) + O_(DoubleBuffer,display[0])),
	store_word(R_0, R_ScreenBuf, O_(DisplayEnv,display_area) + O_(DoubleBuffer,display[0])),
	store_word(R_0, R_ScreenBuf, O_(DisplayEnv,screen)       + O_(DoubleBuffer,display[0])),
	store_word(R_0, R_ScreenBuf, O_(DisplayEnv,vinterlace)   + O_(DoubleBuffer,display[0])),

	/* display[1] = (0, 240, 320, 240); rest of struct zeroed. */
	mac_store_rects2(R_0, R_ScreenY, R_ScreenX, R_ScreenY, R_ScreenBuf, O_(DisplayEnv,display_area) + O_(DoubleBuffer,display[1])),
	store_word(R_0, R_ScreenBuf, O_(DisplayEnv,screen)     + O_(DoubleBuffer,display[1])),
	store_word(R_0, R_ScreenBuf, O_(DisplayEnv,vinterlace) + O_(DoubleBuffer,display[1])),

	mac_store_rects2(R_0, R_ScreenY, R_ScreenX, R_ScreenY, R_ScreenBuf, O_(DrawEnv,clip_area)         + O_(DoubleBuffer,draw[0])), /* draw[0].clip_area = (0, 240, 320, 240). C11's SetDefDrawEnv writes clip.y = y_arg. */
	mac_store_v2s2(  R_0, R_ScreenY,                       R_ScreenBuf, O_(DrawEnv,drawing_offset[0]) + O_(DoubleBuffer,draw[0])), /* draw[0].drawing_offset[0] = (0, 240); C11 passes y_arg as ofs. */

	mac_store_v2s2(R_ScreenX, R_ScreenY, R_ScreenBuf, O_(DrawEnv,clip_area.width) + O_(DoubleBuffer,draw[1])),

	/* draw[0].texture_window = (0, 0, 0, 0); two word-zeroes cover the full 8-byte tw field. */
	store_word(R_0, R_ScreenBuf, O_(DrawEnv,texture_window.x)     + O_(DoubleBuffer,draw[0])),
	store_word(R_0, R_ScreenBuf, O_(DrawEnv,texture_window.width) + O_(DoubleBuffer,draw[0])),

	store_word(R_0, R_ScreenBuf, O_(DrawEnv,drawing_offset[0].x)  + O_(DoubleBuffer,draw[1])),
	store_word(R_0, R_ScreenBuf, O_(DrawEnv,texture_window.x)     + O_(DoubleBuffer,draw[1])),
	store_word(R_0, R_ScreenBuf, O_(DrawEnv,texture_window.width) + O_(DoubleBuffer,draw[1])),

	/* draw[0].texture_page = 10 (gp0_tpage_default). C11 SetDefDrawEnv at C11_only.elf:0x8001273C writes the same 0x0A. . */
	add_ui(R_T0, R_0, gp0_tpage_default),
	store_half(R_T0, R_ScreenBuf, O_(DrawEnv,texture_page) + O_(DoubleBuffer,draw[0])),
	store_half(R_T0, R_ScreenBuf, O_(DrawEnv,texture_page) + O_(DoubleBuffer,draw[1])),

	/* draw[0] control bytes: flag_dither=1, flag_draw_on_display=1 (the dfe bit per psx-spx; libpsyx sets it via `SetDefDrawEnv`'s conditional at C11_only.elf:0x80012728), enable_auto_clear=1. Each byte is named;
	 * the previous `store_word(R_0, ..., +20)` overwrote all four with zero. */
	add_ui(R_T0, R_0, 1),
	store_byte(R_T0, R_ScreenBuf, O_(DrawEnv,flag_dither)          + O_(DoubleBuffer,draw[0])),
	store_byte(R_T0, R_ScreenBuf, O_(DrawEnv,flag_draw_on_display) + O_(DoubleBuffer,draw[0])),
	store_byte(R_T0, R_ScreenBuf, O_(DrawEnv,enable_auto_clear)    + O_(DoubleBuffer,draw[0])),
	store_byte(R_T0, R_ScreenBuf, O_(DrawEnv,flag_dither)          + O_(DoubleBuffer,draw[1])),
	store_byte(R_T0, R_ScreenBuf, O_(DrawEnv,flag_draw_on_display) + O_(DoubleBuffer,draw[1])),
	store_byte(R_T0, R_ScreenBuf, O_(DrawEnv,enable_auto_clear)    + O_(DoubleBuffer,draw[1])),

	/* draw[0].initial_bg_color = (r=7, g=7, b=7). */
	add_ui(R_T0, R_0, 7),
	mac_store_rgb8(R_T0,R_T0,R_T0, R_ScreenBuf, O_(DrawEnv,initial_bg_color) + O_(DoubleBuffer,draw[0])),
	mac_store_rgb8(R_T0,R_T0,R_T0, R_ScreenBuf, O_(DrawEnv,initial_bg_color) + O_(DoubleBuffer,draw[1])),

	mac_yield(),
};

/* gp_screen_init's GPR setup. Tests the mixed user-pinning + auto-reg pattern:
 *   - R_IO_BaseAddr = R_T4 (user-pinned via atom_reg; pre-existing)
 *   - R_GP1_Offset  = R_T2 (user-pinned via atom_reg; NEW -- for GPIO_PORT1_OFFSET)
 *   - R_ScreenX     = R_T5 (user-pinned via atom_reg; used as a transfer and GTE setup reg)
 *   - R_GpTmp       = auto-allocated by the lua pass and used for several GPU transfers;
 *                    the C preprocessor resolves it to the chosen free pool GPR.
 *
 * For gp_screen_init, the auto-reg pool exclusions are:
 *   user_pinned (from the corpus register_alias_registry) : R_T0..R_T7 (all 8 user-pinned across hello_camera.atom.c)
 *   body-parsed physical registers                         : aliases resolve through the registry;
 *                                                           the body uses R_ScreenX, not raw R_T5
 *   source_pool after both subtractions                   : {R_V0, R_V1} only
 *   R_GpTmp gets R_V0 (the first-fit choice). Its repeated GPU-transfer use proves that the
 *   auto-reg allocation is active while the R_ScreenX references prove the pinned alias is used.
 *   R_TapePtr (R_T9), R_AtomJmp (R_T8), R_AT are excluded from the POOL by construction in
 *   passes/auto_reg.lua -- see the "obvious exclusions" comment block at the top of that file.
 */
enum {
	R_IO_BaseAddr = R_T4 atom_reg, /* Caller-pinned: IO_BASE_ADDR = 0x1F800000 */
	R_GP1_Offset  = R_T2 atom_reg, /* Caller-pinned: GPIO_PORT1_OFFSET = 0x10 */
	atom_auto_reg(gp_screen_init, R_GpTmp),  /* Auto-allocated scratch; resolved to a free pool GPR by the lua pass. C-preprocessor expands to R_GpTmp = R_GpTmp_Code with an atom_auto_reg trailing comment. */
#define R_IO_BaseAddr_Code R_T4_Code
#define R_GP1_Offset_Code  R_T2_Code
};
internal MipsAtom_(gp_screen_init) atom_info(atom_phase(screen_init), atom_reads(R_IO_BaseAddr)) {
	store_word(R_0, R_IO_BaseAddr, GPIO_PORT1_OFFSET),                                   /* GP1(00h) Reset */
	mac_gcmd_push(gp1_word_ResetCmdBuffer(),   R_ScreenX, R_IO_BaseAddr, GPIO_PORT1_OFFSET), /* GP1(01h) ClearFIFO; uses pinned R_ScreenX as the transfer reg. */
	mac_gcmd_push(gp1_word_AcknowledgeIRQ(),   R_ScreenX, R_IO_BaseAddr, GPIO_PORT1_OFFSET), /* GP1(02h) AckIRQ; uses pinned R_ScreenX as the transfer reg. */
	mac_gcmd_push(gp1_word_DisplayOn(),        R_ScreenX, R_IO_BaseAddr, GPIO_PORT1_OFFSET), /* GP1(03h) Display ON; uses pinned R_ScreenX as the transfer reg. */
	mac_gcmd_push(gp1_word_dma_to_gpu(),       R_GpTmp,   R_IO_BaseAddr, GPIO_PORT1_OFFSET), /* GP1(04h) DMADirection=2 (CPU->GPU). libpsyx's per-frame PutDrawEnv/DrawOTag use DMA2; without this the DMA queue never drains. Uses auto-allocated R_GpTmp. */
	mac_gcmd_push(gp1_word_StartDisplayArea(), R_GpTmp,   R_IO_BaseAddr, GPIO_PORT1_OFFSET), /* GP1(05h) StartDisplayArea (X=0, Y=0); uses auto-allocated R_GpTmp. */

	/* GP1: DisplayMode + Display Ranges. */
	mac_gcmd_push(gp1_word_display_mode_320x240_15bit_ntsc, R_ScreenX, R_IO_BaseAddr, GPIO_PORT1_OFFSET),
	mac_gcmd_push(gp1_word_horizontal_range_ntsc,           R_ScreenX, R_IO_BaseAddr, GPIO_PORT1_OFFSET),
	mac_gcmd_push(gp1_word_vertical_range_ntsc,             R_ScreenX, R_IO_BaseAddr, GPIO_PORT1_OFFSET),

	/* GTE: SetGeomOffset (OFX, OFY) — ScreenRes_CenterX, ScreenRes_CenterY. */
	load_upper_i(R_ScreenX, ScreenRes_CenterX), gte_mv_to_ctrl_r(R_ScreenX, gte_cr_OFX_Code),
	load_upper_i(R_ScreenX, ScreenRes_CenterY), gte_mv_to_ctrl_r(R_ScreenX, gte_cr_OFY_Code),

	/* GTE: SetGeomScreen (H) — CR26 (per PSX-SPX / libpsyx), value is the raw projection-plane distance, NOT shifted. */
	add_ui(R_ScreenX, R_0, ScreenZ), gte_mv_to_ctrl_r(R_ScreenX, gte_cr_H_Code),

	/* GP1: DisplayEnable — bit 0 = 0 (Display ON). */
	mac_gcmd_push(gp1_word_DisplayOn(), R_GpTmp, R_IO_BaseAddr, GPIO_PORT1_OFFSET), /* Uses auto-allocated R_GpTmp. */
	mac_yield(),
};

typedef Struct_(Binds_PadApplyInput) {
	PadState* state;
	V3_S2*    cube_rot;
	V3_S2*    floor_rot;
};
enum {
	R_PadStateT5 = R_T5 atom_reg,
	R_CubeRot    = R_T1 atom_reg,
	R_FloorRot   = R_T2 atom_reg,
};
internal MipsAtom_(pad_input_cube_rotation) atom_info(atom_bind(Binds_PadApplyInput)
, atom_reads(R_T0, R_CubeRot, R_FloorRot, R_T3, R_T4, R_PadStateT5, R_TapePtr)
, atom_writes(     R_CubeRot, R_FloorRot)
) {
	/* Pop Binds from tape (state, cube_rot, floor_rot) */
	load_word(R_PadStateT5, R_TapePtr, O_(Binds_PadApplyInput,state)),
	load_word(R_CubeRot,    R_TapePtr, O_(Binds_PadApplyInput,cube_rot)),
	load_word(R_FloorRot,   R_TapePtr, O_(Binds_PadApplyInput,floor_rot)),
	LdSlot_ add_ui_self(    R_TapePtr, S_(Binds_PadApplyInput)),

	/* Load pad[0].buttons into R_T0. */
	load_word(R_T0, R_PadStateT5, O_(PadState,buttons)), LdSlot_ nop,
	// Note(Ed): Potential op with delay slot?

	/* D-pad Left: cube_rot.y += 30, floor_rot.y += 5.  */
	and_i(R_T3, R_T0, Pad_Left), branch_le_zero(R_T3, atom_offset(dpad_left, exit_dpad_left)), BdSlot_
		load_half( R_T4, R_CubeRot,  O_(V3_S2,y)), LdSlot_
		load_half( R_T3, R_FloorRot, O_(V3_S2,y)),
		add_si(    R_T4, R_T4, 30),
		add_si(    R_T3, R_T3, 5),
		store_half(R_T4, R_CubeRot,  O_(V3_S2,y)),
		store_half(R_T3, R_FloorRot, O_(V3_S2,y)),
	atom_label(exit_dpad_left)

	/* D-pad Right: cube_rot.y -= 30, floor_rot.y -= 5. */
	and_i(R_T3, R_T0, Pad_Right), branch_le_zero(R_T3, atom_offset(dpad_right, exit_dpad_right)), BdSlot_
		load_half( R_T4, R_CubeRot,  O_(V3_S2,y)), LdSlot_
		load_half( R_T3, R_FloorRot, O_(V3_S2,y)),
		add_si(    R_T4, R_T4, -30),
		add_si(    R_T3, R_T3, -5),
		store_half(R_T4, R_CubeRot,  O_(V3_S2,y)),
		store_half(R_T3, R_FloorRot, O_(V3_S2,y)),
	atom_label(exit_dpad_right)

	/* Analog left-stick X: dead zone 0x70..0x90.
	 * Cube delta = (0x80 - left_x) >> 2; floor delta = (0x80 - left_x) >> 5. */
	load_byte_u(R_T3, R_PadStateT5, O_(PadState,left.x)), LdSlot_ //?

	/* Dead-zone check: skip analog if left_x in [0x70, 0x90] inclusive. Outside dead zone on LOW side: left_x < 0x70 (strictly).
	 * set_lt_u(R_T4, R_T3, R_T4=0x70) → R_T4 = (left_x < 0x70) ? 1 : 0. */
	add_ui(R_T4, R_0, PadDeadZone_HighBound), set_lt_u(R_T4, R_T3, R_T4), branch_ne(R_T4, R_0, atom_offset(dead_zone_low_check, dead_low_active)),
	add_ui(R_T4, R_0, PadDeadZone_Center), /* BD-slot: pre-load 0x80 for dead_low_active */

atom_label(dead_check_upper)
	/* left_x >= 0x70 → check upper bound. */
	load_byte_u(R_T3, R_PadStateT5, O_(PadState,left.x)), /* reload */ LdSlot_ //? 
	add_ui(     R_T4, R_0, PadDeadZone_HighBound),

	/* R_T4 = (0x90 < left_x) ? 1 : 0 → (left_x > 0x90) ? 1 : 0 */
	set_lt_u(R_T4, R_T4, R_T3), branch_ne(R_T4, R_0, atom_offset(dead_zone_high_check, dead_high_active)), BdSlot_
	add_ui(  R_T4, R_0, PadDeadZone_Center), /* BD-slot: pre-load 0x80 for dead_high_active */
	jump_rel(atom_offset(dead_zone_skip, exit_stick)),
		BdSlot_ mac_yield_load(), LdSlot_

atom_label(dead_low_active)
	/* R_T3 = left_x (from line 632 lbu; not clobbered between dead_zone_low_check branch + its BD-slot `add_ui R_T4, 0x80`).
	 * The earlier `load_byte_u(R_T3, ...)` reload was redundant and introduced a load-use hazard on the next `sub_u`.
	 * R_T4 = 0x80 from the BD-slot of `dead_zone_low_check`'s branch_ne. */
	sub_u( R_T3, R_T4, R_T3), /* R_T3 = 0x80 - left_x */
	/* delta = 0x80 - left_x (positive). */

	/* R_T4 = cube_delta */
	shift_aright(R_T4, R_T3, 2),
	load_half(   R_T0, R_CubeRot, O_(V3_S2,y)), LdSlot_ nop,
	add_u(       R_T0, R_T0, R_T4),
	store_half(  R_T0, R_CubeRot, O_(V3_S2,y)),
	/* R_T4 = floor_delta — moved into the load-delay slot of the floor load below (fills the 1-instruction gap;
	 * doesn't read R_T0; R_T4 settles by the subsequent add_u). */
	load_half(   R_T0, R_FloorRot, O_(V3_S2,y)), LdSlot_
	shift_aright(R_T4, R_T3, 5),
	add_u(       R_T0, R_T0, R_T4),
	store_half(  R_T0, R_FloorRot, O_(V3_S2,y)),

	jump_rel(atom_offset(end_low, exit_stick)),
		BdSlot_ mac_yield_load(), LdSlot_

atom_label(dead_high_active)
	/* R_T3 = left_x (from line 641 lbu in dead_check_upper; not clobbered between dead_zone_high_check branch + its BD-slot `add_ui R_T4, 0x80`).
	 * The earlier `load_byte_u(R_T3, ...)` reload was redundant and introduced a load-use hazard on the next `sub_u`.
	 * R_T4 = 0x80 from the BD-slot of `dead_zone_high_check`'s branch_ne. */
	sub_u( R_T3, R_T4, R_T3),
	/* delta = 0x80 - left_x (signed negative). */

	shift_aright(R_T4, R_T3, 2),                      /* R_T4 = cube_delta (signed) */
	load_half(   R_T0, R_CubeRot, O_(V3_S2,y)), LdSlot_ nop,
	add_u(       R_T0, R_T0, R_T4),
	store_half(  R_T0, R_CubeRot, O_(V3_S2,y)),

	/* R_T4 = floor_delta (signed) — moved into the load-delay slot of the floor load below. */
	load_half(   R_T0, R_FloorRot, O_(V3_S2,y)), LdSlot_
	shift_aright(R_T4, R_T3, 5),
	add_u(       R_T0, R_T0, R_T4),
	store_half(  R_T0, R_FloorRot, O_(V3_S2,y)),

atom_label(no_jump_fallthrough)
	mac_yield_load(), LdSlot_

atom_label(exit_stick)
	/* NOT mac_yield() — R_AtomJmp was already loaded in the BD-slot of the dead-zone/exit branch. */
	mac_yield_tail(),
};

enum {
	R_Cam         = R_T4 atom_reg,
	R_CamPadState = R_T5 atom_reg,
};
typedef Struct_(Binds_PadInputCam) {
	PadState* state;
	Camera*   cam;
};
internal MipsAtom_(pad_input_cam) atom_info(atom_bind(Binds_PadInputCam)
, atom_reads( R_Cam, R_CamPadState, R_TapePtr)
, atom_writes(R_Cam)
) {
	/* Bind pop: state → R_CamPadState (R_T5), cam → R_Cam (R_T4), advance R_TapePtr by 8. */
	load_word(R_CamPadState, R_TapePtr, O_(Binds_PadInputCam,state)),
	load_word(R_Cam,         R_TapePtr, O_(Binds_PadInputCam,cam)),
	LdSlot_ add_ui_self(     R_TapePtr, S_(Binds_PadInputCam)),

	/* Load pad[0].buttons into R_T0; nop fills the load-delay slot. */
	load_word(R_T0, R_CamPadState, O_(PadState,buttons)), LdSlot_
	load_word(R_T1, R_Cam, O_(Camera,pos.x)),

	// D-pad Left → cam.pos.x -= 50.  and_i fulfills BD-slot for load on R_Cam.
	LdSlot_ and_i(R_T3, R_T0, Pad_Left), branch_le_zero(R_T3, atom_offset(left_x, exit_left_x)), BdSlot_ nop,
		add_si(R_T1, R_T1, -50), store_word(R_T1, R_Cam, O_(Camera,pos.x)), 
	atom_label(exit_left_x)

	/* D-pad Right → cam.pos.x += 50. Reuses R_T1 from Left. */
	and_i(R_T3, R_T0, Pad_Right), branch_le_zero(R_T3, atom_offset(right_x, exit_right_x)), BdSlot_ nop,
		add_si(R_T1, R_T1,  50), store_word(R_T1, R_Cam, O_(Camera,pos.x)),
	atom_label(exit_right_x)

	/* D-pad Up → cam.pos.y -= 50. Load pos.y BEFORE the andi. */
	load_word(R_T1, R_Cam, O_(Camera,pos.y)), LdSlot_ 
	and_i(R_T3, R_T0, Pad_Up), branch_le_zero(R_T3, atom_offset(up_y, exit_up_y)), BdSlot_ nop,
		add_si(R_T1, R_T1, -50), store_word(R_T1, R_Cam, O_(Camera,pos.y)),
	atom_label(exit_up_y)

	/* D-pad Down → cam.pos.y += 50. Reuses R_T1 from Up. */
	and_i(R_T3, R_T0, Pad_Down), branch_le_zero(R_T3, atom_offset(down_y, exit_down_y)), BdSlot_ nop,
		add_si(R_T1, R_T1,  50), store_word(R_T1, R_Cam, O_(Camera,pos.y)),
	atom_label(exit_down_y)

	/* D-pad Cross → cam.pos.z -= 50. Load pos.z BEFORE the andi. */
	load_word(R_T1, R_Cam, O_(Camera,pos.z)), LdSlot_
	and_i(R_T3, R_T0, Pad_Cross), branch_le_zero(R_T3, atom_offset(cross_z, exit_cross_z)), BdSlot_ load_word(R_AtomJmp, R_TapePtr, 0), LdSlot_ // ac_yield: word 1
		add_si(R_T1, R_T1, -50), store_word(R_T1, R_Cam, O_(Camera,pos.z)),
	atom_label(exit_cross_z)

	/* D-pad Circle → cam.pos.z += 50. Reuses R_T1 from Cross. */
	and_i(R_T3, R_T0, Pad_Circle), branch_le_zero(R_T3, atom_offset(circle_z, exit_circle_z)), BdSlot_ add_ui_self(R_TapePtr, S_(MipsCode)), // ac_yield: word 2
		add_si(R_T1, R_T1,  50), store_word(R_T1, R_Cam, O_(Camera,pos.z)),
	atom_label(exit_circle_z)

	jump_reg(R_AtomJmp), BdSlot_ nop // ac_yield: word 3-4
};

enum {
	R_PrimCursor = R_T7 atom_reg atom_type(U4*),    /* Output cursor (primitive buffer) */
	R_FaceCursor = R_T4 atom_reg atom_type(V4_S2*), /* Cube face-index cursor (V4_S2*); floor context switches to V3_S2* via atom_phase */
	R_VertBase   = R_T5 atom_reg atom_type(V3_S2*), /* Base address of the vertex array */
	R_OtBase     = R_T6 atom_reg atom_type(U4*),    /* Base address of the Ordering Table */
#define R_PrimCursor_Code  R_T7_Code
#define R_FaceCursor_Code  R_T4_Code
#define R_VertBase_Code    R_T5_Code
#define R_OtBase_Code      R_T6_Code
};
typedef Struct_(Binds_CubeTri) {
	U4     PrimCursor;
	V4_S2* FaceCursor;
	V3_S2* VertBase;
	U4*    OtBase;
};
internal MipsAtom_(rbind_cube_g4_face) atom_info(atom_bind(Binds_CubeTri), atom_phase(cube_g4)
,	atom_reads(R_TapePtr)
,	atom_writes(R_PrimCursor, R_FaceCursor, R_VertBase, R_OtBase, R_TapePtr)
){
	/* Pop 4 arguments from the tape directly into the workspace registers */
	load_word(R_PrimCursor, R_TapePtr, O_(Binds_CubeTri,PrimCursor)),
	load_word(R_FaceCursor, R_TapePtr, O_(Binds_CubeTri,FaceCursor)),
	load_word(R_VertBase,   R_TapePtr, O_(Binds_CubeTri,VertBase)),
	load_word(R_OtBase,     R_TapePtr, O_(Binds_CubeTri,OtBase)),
	LdSlot_ add_ui_self(    R_TapePtr, S_(Binds_CubeTri)),
	mac_yield()
};

// cube_g4_face — Draw one cube face (Gouraud-shaded quad) via the GTE tape pipeline
internal
MipsAtom_(cube_g4_face) atom_info(atom_phase(cube_g4),
		atom_reads( R_PrimCursor, R_FaceCursor, R_VertBase, R_OtBase),
		atom_writes(R_PrimCursor, R_FaceCursor)
){
	load_half_u(R_T0, R_FaceCursor, 0 * S_(S2)),
	load_half_u(R_T1, R_FaceCursor, 1 * S_(S2)),
	load_half_u(R_T2, R_FaceCursor, 2 * S_(S2)),
	// load_half_u(R_T3, R_FaceCursor, 3 * S_(S2)),

	LdSlot_ mac_gte_load_tri_verts(R_VertBase, R_T0, R_T1, R_T2), GteDelay_ load_half_u(R_T3, R_FaceCursor, 3 * S_(S2)), LdSlot_
	GteDelay_ nop, gte_cmdw_rotate_translate_perspective_triple,
	gte_cmdw_nclip,

	gte_mv_from_data_r(R_T0, C2_MAC0), GteDelay_ load_word(R_AtomJmp, R_TapePtr, 0), // ac_yield: word 1
	branch_le_zero(R_T0, atom_offset(cull, cube_g4_face_exit)),
		/* BD-slot: Write the prim tag (R_0=0; overwrites the legacy tag word in the prim_buffer).
		 * If branch IS taken (face culled), the body is skipped and this 0-tag is stranded —
		 * harmless because the OT entry that points to this prim is created later. */
		BdSlot_ store_word(R_0, R_PrimCursor, O_(Poly_G4, tag)),
		shift_lleft(R_AT, R_T3, v3s2_byteoff), add_u(R_AT, R_AT, R_VertBase),
		load_word(R_V0, R_AT, O_(V3_S2, x)),   load_word(R_V1, R_AT, O_(V3_S2, z)), LdSlot_
		gte_mv_to_data_r(R_V0, C2_VXY0),       gte_mv_to_data_r(R_V1, C2_VZ0),

		mac_gte_store_g4_p012(R_PrimCursor),
		gte_cmdw_rotate_translate_perspective_single,
		mac_gte_store_g4_p3(R_PrimCursor),

		gte_cmdw_avg_sort_z4,
		gte_mv_from_data_r(R_T1, C2_OTZ),
		add_ui(      R_AT, R_0,  OrderingTbl_Len),
		set_lt_u(    R_AT, R_T1, R_AT),

		branch_equal(R_AT, R_0,  atom_offset(bounds_chk, cube_g4_face_exit)), BdSlot_ add_ui_self(R_TapePtr, S_(MipsCode)), // ac_yield: word 2
			mac_insert_ot_tag(R_OtBase, R_PrimCursor, S_(Poly_G4)),
			mac_format_g4_color(R_PrimCursor,
				/* c0 magenta */ 0xFF, 0x00, 0xFF,
				/* c1 yellow  */ 0xFF, 0xFF, 0x00,
				/* c2 cyan    */ 0x00, 0xFF, 0xFF,
				/* c3 green   */ 0x00, 0xFF, 0x00),
		// end: branch(bounds_chk)
// end: branch(cull)

atom_label(cube_g4_face_exit)
	add_ui_self(R_PrimCursor, S_(Poly_G4)),     /* 9 words = Poly_G4 */
	add_ui_self(R_FaceCursor, S_(S2) * 4),      /* 4 × S2 = 8 bytes */
	jump_reg(R_TapePtr), BdSlot_ nop // ac_yield: word 3-4
};

typedef Struct_(Binds_FloorTri) {
	U4     PrimCursor;
	V3_S2* FaceCursor;
	V3_S2* VertBase;
	U4*    OtBase;
};
internal
MipsAtom_(rbind_floor_f3_face) atom_info(atom_bind(Binds_FloorTri), atom_phase(floor_f3)
	, atom_reads(R_TapePtr)
	, atom_writes(R_PrimCursor, R_FaceCursor, R_VertBase, R_OtBase, R_TapePtr)
){
	/* Pop 4 arguments from the tape directly into the workspace registers */
	load_word(R_PrimCursor, R_TapePtr, O_(Binds_FloorTri,PrimCursor)),
	load_word(R_FaceCursor, R_TapePtr, O_(Binds_FloorTri,FaceCursor)),
	load_word(R_VertBase,   R_TapePtr, O_(Binds_FloorTri,VertBase)),
	load_word(R_OtBase,     R_TapePtr, O_(Binds_FloorTri,OtBase)),
	LdSlot_ add_ui_self(    R_TapePtr, S_(Binds_FloorTri)),
	mac_yield()
};

// atom_dbg_skip
internal
MipsAtom_(floor_f3_face) atom_info(atom_phase(floor_f3)
	, atom_reads( R_PrimCursor, R_FaceCursor, R_VertBase, R_OtBase)
	, atom_writes(R_PrimCursor, R_FaceCursor)
) {
	mac_load_tri_indices(R_FaceCursor, R_T0, R_T1, R_T2),
	mac_gte_load_tri_verts(R_VertBase, R_T0, R_T1, R_T2), GteDelay_ nop2,
	gte_cmdw_rotate_translate_perspective_triple, // 2 nops retire the final cpu -> gte writes before RTPT
	gte_cmdw_nclip,

	/* Culling (Branch forward if Backface) */
	gte_mv_from_data_r(R_T0, C2_MAC0), GteDelay_ load_word(R_AtomJmp, R_TapePtr, 0), // ac_yield: word 1
	branch_le_zero(R_T0, atom_offset(culling, floor_f3_face_exit)), BdSlot_ add_ui_self(R_TapePtr, S_(MipsCode)),  // ac_yield: word 2
		/* Format Primitive */
		mac_gte_store_f3(R_PrimCursor),

		/* Calculate Depth */
		gte_avg_sort_z3,
		gte_mv_from_data_r(R_T1, C2_OTZ),
		/* Bounds Check OTZ < 2048 (Branch forward to skip insertion) */
		add_ui(      R_AT, R_0,  OrderingTbl_Len),
		set_lt_u(    R_AT, R_T1, R_AT),
		branch_equal(R_AT, R_0,  atom_offset(bounds_chk, floor_f3_face_exit)), BdSlot_ nop,
			mac_format_f3_color(R_PrimCursor, 0xFF, 0xFF, 0xFF),  // RGB-form (R=FF, G=FF, B=FF = white)
			mac_insert_ot_tag(R_OtBase, R_PrimCursor, S_(Poly_F3)),   /* Insert into Ordering Table Linked List */
			add_ui_self(R_PrimCursor, S_(Poly_F3)), /* Advance Prim Cursor (5 words) */
				// Note(Ed): No bounds checking, should be checked before atom runs.
		// end: branch(bounds_chk)
	// end: branch(culling)

/* Advance Input Cursor & Yield (Both branch targets land here) */
atom_label(floor_f3_face_exit)
	add_ui_self(R_FaceCursor, S_(S2) * 4),  /* Advance Face Cursor (4 * S2 = 8 bytes) */
	jump_reg(R_TapePtr), BdSlot_ nop // ac_yield: word 3-4
};

typedef Struct_(Binds_SyncPrimitiveArena) { U4 used; U4 cursor; };
internal MipsAtom_(sync_primitive_arena) atom_info(atom_bind(Binds_SyncPrimitiveArena)
	, atom_reads( R_TapePtr, R_PrimCursor)
	, atom_writes(R_TapePtr)
){
	load_word(R_AT, R_TapePtr, O_(Binds_SyncPrimitiveArena,used)),
	load_word(R_T0, R_TapePtr, O_(Binds_SyncPrimitiveArena,cursor)), LdSlot_
	add_ui_self(    R_TapePtr, S_(Binds_SyncPrimitiveArena)),
	/* Calculate byte offset and store directly back to RAM */
	sub_u(     R_T0, R_PrimCursor, R_T0), // R_T0    = R_PrimCursor - binds.cursor
	store_word(R_T0, R_AT, 0),            // R_AT[0] = R_T0
	mac_yield()
};

#pragma endregion Baked Atoms
