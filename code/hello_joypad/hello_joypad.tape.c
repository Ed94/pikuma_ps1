#ifdef INTELLISENSE_DIRECTIVES
#	include "duffle/gen/duffle.macs.h"
#	include "duffle/gen/duffle.offsets.h"
#	include "duffle/atom_dsl.h"
#	include "duffle/lottes_tape.h"
#	include "duffle/mips.h"
#	include "duffle/gte.h"
#	include "duffle/gp.h"
#	include "duffle/pad.h"
#	include "duffle/word_count.metadata.h"
#	include "psyq.h"
#	include "gen/hello_joypad.offsets.h"
#	include "gen/hello_joypad.macs.h"
#	include "hello_joypad.h"
#endif

#pragma region MACs (Mips Atom components)


FI_ MipsAtom ac_store_v2s2(U4 rt_x, U4 rt_y, U4 base, U4 offset) atom_dbg_skip MipsAtomComp_Proc_(ac_store_v2s2, {
	store_half(rt_x, base, offset + O_(V2_S2,x)),
	store_half(rt_y, base, offset + O_(V2_S2,y)),
})

FI_ MipsAtom ac_store_rects2(U4 rt_x, U4 rt_y, U4 rt_width, U4 rt_height, U4 base, U4 offset) atom_dbg_skip MipsAtomComp_Proc_(ac_store_rects2, {
	store_half(rt_x,      base, offset + O_(Rect_S2,x)),
	store_half(rt_y,      base, offset + O_(Rect_S2,y)),
	store_half(rt_width,  base, offset + O_(Rect_S2,width)),
	store_half(rt_height, base, offset + O_(Rect_S2,height)),
})

FI_ MipsAtom ac_store_rgb8(U1 rr, U1 rg, U1 rb, U4 base, U4 offset) atom_dbg_skip MipsAtomComp_Proc_(ac_store_rgb8, {
	store_byte(rr, base, offset + O_(DrawEnv,initial_bg_color.r)),
	store_byte(rg, base, offset + O_(DrawEnv,initial_bg_color.g)),
	store_byte(rb, base, offset + O_(DrawEnv,initial_bg_color.b)),	
})

FI_ MipsAtom ac_gcmd_push(U4 cmd, U4 reg_transfer, U4 reg_base, U2 port)
MipsAtomComp_Proc_(ac_gcmd_push, {
	load_upper_i(reg_transfer, cmd >> 16),
	or_i_self(   reg_transfer, cmd & 0xFFFF),
	store_word(  reg_transfer, reg_base, port),
})

FI_ MipsAtom ac_put_disp_env(U4 reg_transfer, U4 reg_base, U2 port)
MipsAtomComp_Proc_(ac_put_disp_env, {
	// Emits 5 GP0 commands for buffer 0 (display_area = (0,0,320,240)).
	// Sequence per libpsyx PutDispEnv: DrawArea TL → DrawArea BR → Mask → DrawArea TL → DrawArea BR
	mac_gcmd_push(gp0_word_draw_area_top_left_origin,      reg_transfer, reg_base, port),
	mac_gcmd_push(gp0_word_draw_area_bottom_right_320x240, reg_transfer, reg_base, port),
	mac_gcmd_push(gp0_word_set_mask_bit(),                 reg_transfer, reg_base, port),
	mac_gcmd_push(gp0_word_draw_area_top_left_origin,      reg_transfer, reg_base, port),
	mac_gcmd_push(gp0_word_draw_area_bottom_right_320x240, reg_transfer, reg_base, port),
})

FI_ MipsAtom ac_put_draw_env(U4 reg_transfer, U4 reg_base, U2 port)
MipsAtomComp_Proc_(ac_put_draw_env, {
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
	*   tag      = (length << 24) | addr                — 16-word packet (1 tag + 15 code)
	*   code[0]  = DrawMode (dfe=1, dtd=0, tpage=0)     — must come first per libpsyx
	*   code[1]  = TextureWindow (tw=(0,0))             — bare-cmd word; GPU uses current state
	*   code[2]  = DrawArea top-left (clip.x=0, clip.y=240)
	*   code[3]  = DrawArea bottom-right (clip.x+w=320, clip.y+h=480)
	*   code[4]  = DrawOffset (ofs=(0,0))               — bare-cmd word
	*   code[5]  = Mask (dtd=0, dfe=1, isbg=1)          — 0xE6 cmd + isbg bit
	*   code[6]  = Initial-bg-color (isbg=1, r=7, g=7, b=7)
	*   code[7]  = DrawMode (isbg=1, tpage=0)           — re-asserts DrawMode with isbg
	*   code[8..10]  = padding (NOP)                    — 3 words to fill the packet
	*   code[11..12] = TextureWindow bottom-right       — defaults to (0,0,0,0)
	*   code[13..14] = padding (NOP)                    — completes the 16-word packet
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

/* ac_pad_sio_write_pad_state
 * raw_sio_pad_poll_20260802 — Task 3.1 helper component.
 * Writes the per-port PadState in 5 instructions plus 4 store_word calls (status,
 * buttons, left_x/y/right_x/right_y packed, attempt). The provisional decode publishes
 * 0x0000FFFF buttons + centered axes on every path until response-byte decode lands.
 *
 * Args:
 *   status_val    - the PadSioStatus enum value to publish
 *   state_ptr_reg - the PadState* base (R_PadState at the call site)
 *   scratch_reg   - scratch register for the value being stored (e.g., R_T0)
 *
 * Emits 9 instructions (status/buttons/axes/attempt stores plus the
 * two-instruction zero-extended buttons load).
 */
FI_ MipsAtom ac_pad_sio_write_pad_state(U4 status_val, U4 state_ptr_reg, U4 scratch_reg)
MipsAtomComp_Proc_(ac_pad_sio_write_pad_state, {
	add_ui(scratch_reg, R_0, status_val),
	store_word(scratch_reg, state_ptr_reg, O_(PadState,status)),
	/* FIX 2026-08-02: buttons = 0x0000FFFF = "no buttons pressed" in
	 * libetc convention. Build it with LUI + ORI so addiu does not
	 * sign-extend 0xFFFF to 0xFFFFFFFF. */
	load_upper_i(scratch_reg, 0x0000),
	or_i(scratch_reg, scratch_reg, 0xFFFF),
	store_word(scratch_reg, state_ptr_reg, O_(PadState,buttons)),
	add_ui(scratch_reg, R_0, 0x80808080),
	store_word(scratch_reg, state_ptr_reg, O_(PadState,left_x)),
	add_ui(scratch_reg, R_0, 0),
	store_word(scratch_reg, state_ptr_reg, O_(PadState,attempt))
})

#pragma endregion MACs

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
	mac_store_v2s2(R_ScreenX, R_ScreenY, R_ScreenBuf, O_(DisplayEnv,display_area.width) + OA_(DoubleBuffer,display,0)),
	store_word(R_0, R_ScreenBuf, O_(DisplayEnv,display_area) + OA_(DoubleBuffer,display,0)),
	store_word(R_0, R_ScreenBuf, O_(DisplayEnv,screen)       + OA_(DoubleBuffer,display,0)),
	store_word(R_0, R_ScreenBuf, O_(DisplayEnv,vinterlace)   + OA_(DoubleBuffer,display,0)),

	/* display[1] = (0, 240, 320, 240); rest of struct zeroed. */
	mac_store_rects2(R_0, R_ScreenY, R_ScreenX, R_ScreenY, R_ScreenBuf, O_(DisplayEnv,display_area) + OA_(DoubleBuffer,display,1)),
	store_word(R_0, R_ScreenBuf, O_(DisplayEnv,screen)     + OA_(DoubleBuffer,display,1)),
	store_word(R_0, R_ScreenBuf, O_(DisplayEnv,vinterlace) + OA_(DoubleBuffer,display,1)),

	mac_store_rects2(R_0, R_ScreenY, R_ScreenX, R_ScreenY, R_ScreenBuf, O_(DrawEnv,clip_area)         + OA_(DoubleBuffer,draw,0)), /* draw[0].clip_area = (0, 240, 320, 240). C11's SetDefDrawEnv writes clip.y = y_arg. */
	mac_store_v2s2(  R_0, R_ScreenY,                       R_ScreenBuf, O_(DrawEnv,drawing_offset[0]) + OA_(DoubleBuffer,draw,0)), /* draw[0].drawing_offset[0] = (0, 240); C11 passes y_arg as ofs. */

	mac_store_v2s2(R_ScreenX, R_ScreenY, R_ScreenBuf, O_(DrawEnv,clip_area.width) + OA_(DoubleBuffer,draw,1)),

	/* draw[0].texture_window = (0, 0, 0, 0); two word-zeroes cover the full 8-byte tw field. */
	store_word(R_0, R_ScreenBuf, O_(DrawEnv,texture_window.x)     + OA_(DoubleBuffer,draw,0)),
	store_word(R_0, R_ScreenBuf, O_(DrawEnv,texture_window.width) + OA_(DoubleBuffer,draw,0)),

	store_word(R_0, R_ScreenBuf, O_(DrawEnv,drawing_offset[0].x)  + OA_(DoubleBuffer,draw,1)),
	store_word(R_0, R_ScreenBuf, O_(DrawEnv,texture_window.x)     + OA_(DoubleBuffer,draw,1)),
	store_word(R_0, R_ScreenBuf, O_(DrawEnv,texture_window.width) + OA_(DoubleBuffer,draw,1)),

	/* draw[0].texture_page = 10 (gp0_tpage_default). C11 SetDefDrawEnv at C11_only.elf:0x8001273C writes the same 0x0A. . */
	add_ui(R_T0, R_0, gp0_tpage_default), 
	store_half(R_T0, R_ScreenBuf, O_(DrawEnv,texture_page) + OA_(DoubleBuffer,draw,0)),
	store_half(R_T0, R_ScreenBuf, O_(DrawEnv,texture_page) + OA_(DoubleBuffer,draw,1)),

	/* draw[0] control bytes: flag_dither=1, flag_draw_on_display=1 (the dfe bit per psx-spx; libpsyx sets it via `SetDefDrawEnv`'s conditional at C11_only.elf:0x80012728), enable_auto_clear=1. Each byte is named;
	 * the previous `store_word(R_0, ..., +20)` overwrote all four with zero. */
	add_ui(R_T0, R_0, 1),
	store_byte(R_T0, R_ScreenBuf, O_(DrawEnv,flag_dither)          + OA_(DoubleBuffer,draw,0)),
	store_byte(R_T0, R_ScreenBuf, O_(DrawEnv,flag_draw_on_display) + OA_(DoubleBuffer,draw,0)),
	store_byte(R_T0, R_ScreenBuf, O_(DrawEnv,enable_auto_clear)    + OA_(DoubleBuffer,draw,0)),
	store_byte(R_T0, R_ScreenBuf, O_(DrawEnv,flag_dither)          + OA_(DoubleBuffer,draw,1)),
	store_byte(R_T0, R_ScreenBuf, O_(DrawEnv,flag_draw_on_display) + OA_(DoubleBuffer,draw,1)),
	store_byte(R_T0, R_ScreenBuf, O_(DrawEnv,enable_auto_clear)    + OA_(DoubleBuffer,draw,1)),

	/* draw[0].initial_bg_color = (r=7, g=7, b=7). */
	add_ui(R_T0, R_0, 7), 
	mac_store_rgb8(R_T0,R_T0,R_T0, R_ScreenBuf, O_(DrawEnv,initial_bg_color) + OA_(DoubleBuffer,draw,0)),
	mac_store_rgb8(R_T0,R_T0,R_T0, R_ScreenBuf, O_(DrawEnv,initial_bg_color) + OA_(DoubleBuffer,draw,1)),

	mac_yield(),
};

enum {
	R_IO_BaseAddr = R_T4 atom_reg, /* Caller-pinned: IO_BASE_ADDR = 0x1F800000 */
#define R_IO_BaseAddr_Code R_T4_Code
};
internal MipsAtom_(gp_screen_init) atom_info(atom_phase(screen_init), atom_reads(R_IO_BaseAddr)) {
	store_word(R_0, R_IO_BaseAddr, GPIO_PORT1_OFFSET),                                   /* GP1(00h) Reset */
	mac_gcmd_push(gp1_word_ResetCmdBuffer(),   R_T5, R_IO_BaseAddr, GPIO_PORT1_OFFSET),  /* GP1(01h) ClearFIFO */
	mac_gcmd_push(gp1_word_AcknowledgeIRQ(),   R_T5, R_IO_BaseAddr, GPIO_PORT1_OFFSET),  /* GP1(02h) AckIRQ */
	mac_gcmd_push(gp1_word_DisplayOn(),        R_T5, R_IO_BaseAddr, GPIO_PORT1_OFFSET),  /* GP1(03h) Display ON */
	mac_gcmd_push(gp1_word_dma_to_gpu(),       R_T5, R_IO_BaseAddr, GPIO_PORT1_OFFSET),  /* GP1(04h) DMADirection=2 (CPU→GPU). libpsyx's per-frame PutDrawEnv/DrawOTag use DMA2; without this the DMA queue never drains. */
	mac_gcmd_push(gp1_word_StartDisplayArea(), R_T5, R_IO_BaseAddr, GPIO_PORT1_OFFSET),  /* GP1(05h) StartDisplayArea (X=0, Y=0) */

	/* GP1: DisplayMode + Display Ranges */
	mac_gcmd_push(gp1_word_display_mode_320x240_15bit_ntsc, R_T5, R_IO_BaseAddr, GPIO_PORT1_OFFSET),
	mac_gcmd_push(gp1_word_horizontal_range_ntsc,           R_T5, R_IO_BaseAddr, GPIO_PORT1_OFFSET),
	mac_gcmd_push(gp1_word_vertical_range_ntsc,             R_T5, R_IO_BaseAddr, GPIO_PORT1_OFFSET),

	/* GTE: SetGeomOffset (OFX, OFY) — ScreenRes_CenterX, ScreenRes_CenterY. */
	load_upper_i(R_T5, ScreenRes_CenterX), gte_mv_to_ctrl_r(R_T5, gte_cr_OFX_Code),
	load_upper_i(R_T5, ScreenRes_CenterY), gte_mv_to_ctrl_r(R_T5, gte_cr_OFY_Code),

	/* GTE: SetGeomScreen (H) — CR26 (per PSX-SPX / libpsyx), value is the raw projection-plane distance, NOT shifted. */
	add_ui(R_T5, R_0, ScreenZ), gte_mv_to_ctrl_r(R_T5, gte_cr_H_Code),

	/* GP1: DisplayEnable — bit 0 = 0 (Display ON). */
	mac_gcmd_push(gp1_word_DisplayOn(), R_T5, R_IO_BaseAddr, GPIO_PORT1_OFFSET),
	mac_yield(),
};

enum {
	R_PadInState  = R_T4 atom_reg atom_type(U4),
	R_PadSignal = R_T0 atom_reg atom_type(U4),
	R_CubeRot   = R_T1 atom_reg atom_type(V3_S2*),
	R_FloorRot  = R_T2 atom_reg atom_type(V3_S2*),
};
typedef Struct_(Binds_PadInputDemo) {
	U4     pad_state;
	V3_S2* cube_rot;
	V3_S2* floor_rot;
};
internal MipsAtom_(pad_input_demo) atom_info(atom_bind(Binds_PadInputDemo)
, atom_reads(R_PadInState, R_CubeRot, R_FloorRot)
, atom_writes(R_CubeRot, R_FloorRot)
) {
	load_word(R_PadInState, R_TapePtr, O_(Binds_PadInputDemo,pad_state)),
	load_word(R_CubeRot,  R_TapePtr, O_(Binds_PadInputDemo,cube_rot)),
	load_word(R_FloorRot, R_TapePtr, O_(Binds_PadInputDemo,floor_rot)),
	add_ui_self(          R_TapePtr, S_(Binds_PadInputDemo)),

	and_i(R_PadSignal, R_PadInState, pad0_(Pad_Left)), branch_le_zero(R_PadSignal, atom_offset(pad_left, exit_pad_left)),
		load_half( R_T5, R_CubeRot,  O_(V3_S2,y)), // BD-Slot occupied
		load_half( R_T6, R_FloorRot, O_(V3_S2,y)),
		add_si(    R_T5, R_T5, 30),
		add_si(    R_T6, R_T6, 5),
		store_half(R_T5, R_CubeRot,  O_(V3_S2,y)),
		store_half(R_T6, R_FloorRot, O_(V3_S2,y)),
	atom_label(exit_pad_left)

	and_i(R_PadSignal, R_PadInState, pad0_(Pad_Right)), branch_le_zero(R_PadSignal, atom_offset(pad_right, exit_pad_right)),
		load_half( R_T5, R_CubeRot,  O_(V3_S2,y)), // BD-Slot occupied
		load_half( R_T6, R_FloorRot, O_(V3_S2,y)),
		add_si(    R_T5, R_T5, -30),
		add_si(    R_T6, R_T6, -5),
		store_half(R_T5, R_CubeRot,  O_(V3_S2,y)),
		store_half(R_T6, R_FloorRot, O_(V3_S2,y)),
	atom_label(exit_pad_right)

	mac_yield(),
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
	add_ui_self(            R_TapePtr, S_(Binds_CubeTri)),
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
	load_half_u(R_T3, R_FaceCursor, 3 * S_(S2)),

	mac_gte_load_tri_verts(R_T0, R_T1, R_T2),
	nop2, gte_cmdw_rotate_translate_perspective_triple, // required cpu -> gte delay slot
	gte_cmdw_nclip,

	gte_mv_from_data_r(R_T0, C2_MAC0), nop,
	branch_le_zero(R_T0, atom_offset(cull, cube_g4_face_exit)), nop,
		store_word(R_0, R_PrimCursor, O_(Poly_G4, tag)),
		shift_lleft(R_AT, R_T3, v3s2_byteoff), add_u(R_AT, R_AT, R_VertBase),
		load_word(R_V0, R_AT, O_(V3_S2, x)),   load_word(R_V1, R_AT, O_(V3_S2, z)),
		gte_mv_to_data_r(R_V0, C2_VXY0),       gte_mv_to_data_r(R_V1, C2_VZ0),

		mac_gte_store_g4_p012(),
		gte_cmdw_rotate_translate_perspective_single,
		mac_gte_store_g4_p3(),

		gte_cmdw_avg_sort_z4,
		gte_mv_from_data_r(R_T1, C2_OTZ),
		add_ui(      R_AT, R_0,  OrderingTbl_Len),
		set_lt_u(    R_AT, R_T1, R_AT),

		branch_equal(R_AT, R_0,  atom_offset(bounds_chk, cube_g4_face_exit)), nop,
			mac_insert_ot_tag_g4(),
			mac_format_g4_color(
				/* c0 magenta */ 0xFF, 0x00, 0xFF,
				/* c1 yellow  */ 0xFF, 0xFF, 0x00,
				/* c2 cyan    */ 0x00, 0xFF, 0xFF,
				/* c3 green   */ 0x00, 0xFF, 0x00),
		// end: branch(bounds_chk)
// end: branch(cull)

atom_label(cube_g4_face_exit)
	add_ui_self(R_PrimCursor, S_(Poly_G4)),     /* 9 words = Poly_G4 */
	add_ui_self(R_FaceCursor, S_(S2) * 4),      /* 4 × S2 = 8 bytes */
	mac_yield()
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
	add_ui_self(            R_TapePtr, S_(Binds_FloorTri)),
	mac_yield()
};

// atom_dbg_skip
internal
MipsAtom_(floor_f3_face) atom_info(atom_phase(floor_f3)
	, atom_reads( R_PrimCursor, R_FaceCursor, R_VertBase, R_OtBase)
	, atom_writes(R_PrimCursor, R_FaceCursor)
) {
	mac_load_tri_indices(  R_T0, R_T1, R_T2),
	mac_gte_load_tri_verts(R_T0, R_T1, R_T2),
	nop2, gte_cmdw_rotate_translate_perspective_triple, // 2 nops retire the final cpu -> gte writes before RTPT
	gte_cmdw_nclip,

	/* Culling (Branch forward if Backface) */
	gte_mv_from_data_r(R_T0, C2_MAC0),
	nop, branch_le_zero(R_T0, atom_offset(culling, floor_f3_face_exit)), nop, // required gte -> cpu load-delay slot. 
		/* Format Primitive */
		mac_gte_store_f3(),

		/* Calculate Depth */
		gte_avg_sort_z3,
		gte_mv_from_data_r(R_T1, C2_OTZ),
		/* Bounds Check OTZ < 2048 (Branch forward to skip insertion) */
		add_ui(      R_AT, R_0,  OrderingTbl_Len),
		set_lt_u(    R_AT, R_T1, R_AT),
		branch_equal(R_AT, R_0,  atom_offset(bounds_chk, floor_f3_face_exit)), nop,
			mac_format_f3_color(0xFF, 0xFF, 0xFF),  // RGB-form (R=FF, G=FF, B=FF = white)
			mac_insert_ot_tag_f3(),                 /* Insert into Ordering Table Linked List */
			add_ui_self(R_PrimCursor, S_(Poly_F3)), /* Advance Prim Cursor (5 words) */
				// Note(Ed): No bounds checking, should be checked before atom runs.
		// end: branch(bounds_chk)
	// end: branch(culling)

/* Advance Input Cursor & Yield (Both branch targets land here) */
atom_label(floor_f3_face_exit)
	add_ui_self(R_FaceCursor, S_(S2) * 4),  /* Advance Face Cursor (4 * S2 = 8 bytes) */
	mac_yield()
};

typedef Struct_(Binds_SyncPrimitiveArena) { U4 used; U4 cursor; };
internal MipsAtom_(sync_primitive_arena) atom_info(atom_bind(Binds_SyncPrimitiveArena)
	, atom_reads( R_TapePtr, R_PrimCursor)
	, atom_writes(R_TapePtr)
){
	load_word(R_AT, R_TapePtr, O_(Binds_SyncPrimitiveArena,used)),
	load_word(R_T0, R_TapePtr, O_(Binds_SyncPrimitiveArena,cursor)),
	add_ui_self(    R_TapePtr, S_(Binds_SyncPrimitiveArena)),
	/* Calculate byte offset and store directly back to RAM */
	sub_u(     R_T0, R_PrimCursor, R_T0), // R_T0    = R_PrimCursor - binds.cursor
	store_word(R_T0, R_AT, 0),            // R_AT[0] = R_T0
	mac_yield()
};

/* ----- pad_sio_init -----
 * Boot-time SIO0 init. Caller pins R_T6 = sio_base_addr0.
 * Issues SIO CTRL=0x0040 (reset), MODE=0x000D, BAUD=0x0088.
 * (Phase 2 fills the body.)
 */
internal MipsAtom_(pad_sio_init) atom_info(atom_phase(pad_init)
, atom_reads(R_T5, R_T6)
, atom_writes(R_T5, R_T6)
) {
	/* FIX 2026-08-02: explicitly load the KSEG1 base into R_T6 at the top of
	 * the atom body. The rgcc(R_PadSioBase) binding in main() pins R_T6 = base
	 * when main() runs, but $12 is caller-saved per the O32 ABI — when tape_run
	 * is invoked, R_T6 is fair game. The atom body cannot rely on the value. */
	load_upper_i(R_T6, pad_IO_KSEG1_BASE >> 16),   /* R_T6 high 16 = 0xBF80 */
	or_i(R_T6, R_T6, pad_IO_KSEG1_BASE & 0xFFFF),   /* R_T6 = 0xBF800000 */

	/* SIO CTRL = 0x0040 (reset) */
	add_ui(R_T5, R_0, pad_SIO_CTRL_RESET),
	store_half(R_T5, R_T6, pad_SIO_CTRL_OFFSET),
	/* SIO MODE = 0x000D (MUL1, 8-bit, no parity, idle-high) */
	add_ui(R_T5, R_0, pad_SIO_MODE_INIT),
	store_half(R_T5, R_T6, pad_SIO_MODE_OFFSET),
	/* SIO BAUD = 0x0088 (~250 kHz) */
	add_ui(R_T5, R_0, pad_SIO_BAUD_INIT),
	store_half(R_T5, R_T6, pad_SIO_BAUD_OFFSET),
	mac_yield(),
};

/* ----- pad_sio_step -----
 * Per-frame bounded raw-SIO transaction. Reads PadState pointers + SIO
 * base addresses from Binds_PadSioStep; writes per-port status +
 * buttons + axes into smem.pad[0..1].
 *
 * Body shape (per spec §"Transaction model (per port, per pad_sio_step)"):
 *   port 0: CTRL=CLEANUP → settle → CTRL=port-select → settle → exchange 5
 *           bytes (addr + 0x42 0x00 0x00 0x00) → decode → write PadState[0]
 *           → CTRL=CLEANUP.
 *   port 1: swap scratch regs (sio_base_addr1 → R_PadSioBase, state1 →
 *           R_PadState) → mirror port 0 sequence.
 *
 * Bounded-loop semantics: every countdown is wrapped in
 *   add_ui_self(R_T1, -1) + branch_ne(R_T1, R_0, ...)
 * with a known maximum (pad_SIO_SETTLE_BEFORE_TX=1000, pad_SIO_SETTLE_AFTER_TX=2000,
 * pad_SIO_WAIT_BUDGET=4096). The static-analysis pass currently reports
 * has_loops = true; the follow-up metaprogram track that learns modeled-bounded
 * loops is out of scope here (per spec §"Risks").
 *
 * Scratch register strategy:
 *   R_PadStatus    = R_T4 — RESERVED for port-1 swap (holds state1)
 *   R_PadCountdown = R_T5 — RESERVED for port-1 swap (holds sio_base_addr1)
 *   R_T0           — byte-exchange value + STAT read (clobbered freely)
 *   R_T1           — countdown budget (clobbered freely)
 *   R_PadState     = R_T7 — PadState* (preserved for PadState writes)
 *   R_PadSioBase   = R_T6 — SIO base (preserved through the port)
 *
 * Response decode (Task 3.1 teaching scope):
 *   - status   = PadSioStatus_Digital (hardcoded)
 *   - buttons  = 0xFFFF (no buttons pressed in the provisional libetc
 *                         convention; full response-byte decode is follow-up)
 *   - axes     = 0x80808080 (centered: left_x=0x80, left_y=0x80,
 *                             right_x=0x80, right_y=0x80)
 *   - attempt  = 0
 *   - DualShock handshake (0x43 0x01 → 0x44 0x01 0x03 → 0x43 0x00) is
 *     follow-up scope; the hardcoded digital decode is a placeholder.
 *
 * Both ports raise /CS (CTRL = pad_SIO_CTRL_CLEANUP) before exit. Both ports
 * treat response timeout as PadSioStatus_Disconnected per the spec §"Failure
 * handling" + the canonical per-port timeout semantics.
 */
internal MipsAtom_(pad_sio_step) atom_info(atom_bind(Binds_PadSioStep)
, atom_reads(R_TapePtr, R_PadSioBase, R_PadState, R_PadStatus, R_PadCountdown)
, atom_writes(R_PadStatus, R_PadCountdown)
) {
	/* FIX 2026-08-02: explicitly load KSEG1 base into R_PadSioBase (R_T6) at the
	 * top. The rgcc() binding in main() does NOT survive the tape_run call
	 * because R_T6 is caller-saved per the O32 ABI. The pad_sio_init atom
	 * (also in the per-frame tape) reloads R_T6 separately. */
	load_upper_i(R_PadSioBase, pad_IO_KSEG1_BASE >> 16),
	or_i(R_PadSioBase, R_PadSioBase, pad_IO_KSEG1_BASE & 0xFFFF),

	/* Pop Binds from tape (in Binds_PadSioStep declaration order) */
	load_word(R_PadState,     R_TapePtr, O_(Binds_PadSioStep,state0)),
	load_word(R_PadStatus,    R_TapePtr, O_(Binds_PadSioStep,state1)),    /* reserved for port-1 swap */
	load_word(R_PadSioBase,   R_TapePtr, O_(Binds_PadSioStep,sio_base_addr0)),
	load_word(R_PadCountdown, R_TapePtr, O_(Binds_PadSioStep,sio_base_addr1)),  /* reserved for port-1 swap */
	add_ui_self(R_TapePtr, S_(Binds_PadSioStep)),

	/* ============== PORT 0 TRANSACTION ============== */
	/* Use R_T0 (byte value / STAT read) + R_T1 (countdown) as scratch.
	 * R_PadStatus (state1) + R_PadCountdown (sio_base_addr1) are preserved
	 * through the port-0 body and swapped into R_PadSioBase + R_PadState
	 * at atom_offset(port1_start, ...) below. */

	/* 1. Cleanup: CTRL = 0x0010 (raise /CS, clear stale status) */
	add_ui(R_T0, R_0, pad_SIO_CTRL_CLEANUP),
	store_half(R_T0, R_PadSioBase, pad_SIO_CTRL_OFFSET),
	/* Bounded by pad_SIO_SETTLE_BEFORE_TX = 1000 iterations. */
	add_ui(R_T1, R_0, pad_SIO_SETTLE_BEFORE_TX),
atom_label(settle_pre_port0)
	nop,  /* BD slot */
	add_ui_self(R_T1, -1),
	branch_ne(R_T1, R_0, atom_offset(settle_pre_port0, settle_pre_port0)),

	/* 2. Port-select: CTRL = 0x0003 (TX enable + DTR /CS) for port 0 */
	add_ui(R_T0, R_0, pad_SIO_CTRL_TX_ENABLE),
	or_i(R_T0, R_T0, pad_SIO_CTRL_DTR_CS),  /* set /CS line low */
	store_half(R_T0, R_PadSioBase, pad_SIO_CTRL_OFFSET),
	/* Bounded by pad_SIO_SETTLE_AFTER_TX = 2000 iterations. */
	add_ui(R_T1, R_0, pad_SIO_SETTLE_AFTER_TX),
atom_label(settle_post_port0)
	nop,
	add_ui_self(R_T1, -1),
	branch_ne(R_T1, R_0, atom_offset(settle_post_port0, settle_post_port0)),

	/* 3. Address byte (0x01) — send + RX-ready wait + read response + RX-drain confirmation */
	add_ui(R_T0, R_0, pad_PROTO_ADDR),
	store_byte(R_T0, R_PadSioBase, pad_SIO_DATA_OFFSET),

	/* Bounded by pad_SIO_WAIT_BUDGET = 4096 iterations. */
	add_ui(R_T1, R_0, pad_SIO_WAIT_BUDGET),
atom_label(wait_ack0_port0)
	load_half_u(R_T0, R_PadSioBase, pad_SIO_STAT_OFFSET),
	nop,
	and_i(R_T0, R_T0, pad_SIO_STAT_RX_NOT_EMPTY),
	branch_ne(R_T0, R_0, atom_offset(wait_ack0_port0, ack0_received_port0)),
	add_ui_self(R_T1, -1),
atom_label(continue_wait_ack0_port0)
	branch_ne(R_T1, R_0, atom_offset(continue_wait_ack0_port0, wait_ack0_port0)),
	/* RX timeout → mark disconnected; skip to port 1 */
	mac_pad_sio_write_pad_state(PadSioStatus_Disconnected, R_PadState, R_T0),
atom_label(skip_port0_from_ack0)
	branch_equal(R_0, R_0, atom_offset(skip_port0_from_ack0, port1_start)),

atom_label(ack0_received_port0)
	/* Read open-bus response byte 0 — discard per docs/psx-spx §controllersandmemorycards.md */
	load_byte_u(R_T0, R_PadSioBase, pad_SIO_DATA_OFFSET),

	/* Confirm RX FIFO drained before sending byte 1. Bounded by pad_SIO_WAIT_BUDGET = 4096 iterations. */
	add_ui(R_T1, R_0, pad_SIO_WAIT_BUDGET),
atom_label(wait_ackrel0_port0)
	load_half_u(R_T0, R_PadSioBase, pad_SIO_STAT_OFFSET),
	nop,
	and_i(R_T0, R_T0, pad_SIO_STAT_RX_NOT_EMPTY),
	branch_equal(R_T0, R_0, atom_offset(wait_ackrel0_port0, ack_released_port0)),
	add_ui_self(R_T1, -1),
atom_label(continue_wait_ackrel0_port0)
	branch_ne(R_T1, R_0, atom_offset(continue_wait_ackrel0_port0, wait_ackrel0_port0)),
	/* RX-drain timeout → disconnected; skip to port 1 */
	mac_pad_sio_write_pad_state(PadSioStatus_Disconnected, R_PadState, R_T0),
atom_label(skip_port0_from_ackrel0)
	branch_equal(R_0, R_0, atom_offset(skip_port0_from_ackrel0, port1_start)),

atom_label(ack_released_port0)

	/* === Byte 1 (port 0): send 0x42 (cmd read) + RX-ready wait + read response + RX-drain confirmation === */
	/* Bounded by pad_SIO_WAIT_BUDGET = 4096 iterations. */
	add_ui(R_T0, R_0, pad_PROTO_CMD_READ),
	store_byte(R_T0, R_PadSioBase, pad_SIO_DATA_OFFSET),
	add_ui(R_T1, R_0, pad_SIO_WAIT_BUDGET),
atom_label(wait_ack1_port0)
	load_half_u(R_T0, R_PadSioBase, pad_SIO_STAT_OFFSET),
	nop,
	and_i(R_T0, R_T0, pad_SIO_STAT_RX_NOT_EMPTY),
	branch_ne(R_T0, R_0, atom_offset(wait_ack1_port0, ack1_received_port0)),
	add_ui_self(R_T1, -1),
atom_label(continue_wait_ack1_port0)
	branch_ne(R_T1, R_0, atom_offset(continue_wait_ack1_port0, wait_ack1_port0)),
	mac_pad_sio_write_pad_state(PadSioStatus_Disconnected, R_PadState, R_T0),
atom_label(skip_port0_from_ack1)
	branch_equal(R_0, R_0, atom_offset(skip_port0_from_ack1, port1_start)),

atom_label(ack1_received_port0)
	/* Read response ID byte — discarded for teaching scope (decode hardcoded). */
	load_byte_u(R_T0, R_PadSioBase, pad_SIO_DATA_OFFSET),

	/* RX FIFO drain wait. Bounded by pad_SIO_WAIT_BUDGET = 4096 iterations. */
	add_ui(R_T1, R_0, pad_SIO_WAIT_BUDGET),
atom_label(wait_ackrel1_port0)
	load_half_u(R_T0, R_PadSioBase, pad_SIO_STAT_OFFSET),
	nop,
	and_i(R_T0, R_T0, pad_SIO_STAT_RX_NOT_EMPTY),
	branch_equal(R_T0, R_0, atom_offset(wait_ackrel1_port0, ack_released1_port0)),
	add_ui_self(R_T1, -1),
atom_label(continue_wait_ackrel1_port0)
	branch_ne(R_T1, R_0, atom_offset(continue_wait_ackrel1_port0, wait_ackrel1_port0)),
	mac_pad_sio_write_pad_state(PadSioStatus_Disconnected, R_PadState, R_T0),
atom_label(skip_port0_from_ackrel1)
	branch_equal(R_0, R_0, atom_offset(skip_port0_from_ackrel1, port1_start)),

atom_label(ack_released1_port0)

	/* === Byte 2 (port 0): send 0x00 + RX-ready wait + read response + RX-drain confirmation === */
	/* Bounded by pad_SIO_WAIT_BUDGET = 4096 iterations. */
	add_ui(R_T0, R_0, 0x00),
	store_byte(R_T0, R_PadSioBase, pad_SIO_DATA_OFFSET),
	add_ui(R_T1, R_0, pad_SIO_WAIT_BUDGET),
atom_label(wait_ack2_port0)
	load_half_u(R_T0, R_PadSioBase, pad_SIO_STAT_OFFSET),
	nop,
	and_i(R_T0, R_T0, pad_SIO_STAT_RX_NOT_EMPTY),
	branch_ne(R_T0, R_0, atom_offset(wait_ack2_port0, ack2_received_port0)),
	add_ui_self(R_T1, -1),
atom_label(continue_wait_ack2_port0)
	branch_ne(R_T1, R_0, atom_offset(continue_wait_ack2_port0, wait_ack2_port0)),
	mac_pad_sio_write_pad_state(PadSioStatus_Disconnected, R_PadState, R_T0),
atom_label(skip_port0_from_ack2)
	branch_equal(R_0, R_0, atom_offset(skip_port0_from_ack2, port1_start)),

atom_label(ack2_received_port0)
	load_byte_u(R_T0, R_PadSioBase, pad_SIO_DATA_OFFSET),

	/* Bounded by pad_SIO_WAIT_BUDGET = 4096 iterations. */
	add_ui(R_T1, R_0, pad_SIO_WAIT_BUDGET),
atom_label(wait_ackrel2_port0)
	load_half_u(R_T0, R_PadSioBase, pad_SIO_STAT_OFFSET),
	nop,
	and_i(R_T0, R_T0, pad_SIO_STAT_RX_NOT_EMPTY),
	branch_equal(R_T0, R_0, atom_offset(wait_ackrel2_port0, ack_released2_port0)),
	add_ui_self(R_T1, -1),
atom_label(continue_wait_ackrel2_port0)
	branch_ne(R_T1, R_0, atom_offset(continue_wait_ackrel2_port0, wait_ackrel2_port0)),
	mac_pad_sio_write_pad_state(PadSioStatus_Disconnected, R_PadState, R_T0),
atom_label(skip_port0_from_ackrel2)
	branch_equal(R_0, R_0, atom_offset(skip_port0_from_ackrel2, port1_start)),

atom_label(ack_released2_port0)

	/* === Byte 3 (port 0): send 0x00 + RX-ready wait + read response + RX-drain confirmation === */
	/* Bounded by pad_SIO_WAIT_BUDGET = 4096 iterations. */
	add_ui(R_T0, R_0, 0x00),
	store_byte(R_T0, R_PadSioBase, pad_SIO_DATA_OFFSET),
	add_ui(R_T1, R_0, pad_SIO_WAIT_BUDGET),
atom_label(wait_ack3_port0)
	load_half_u(R_T0, R_PadSioBase, pad_SIO_STAT_OFFSET),
	nop,
	and_i(R_T0, R_T0, pad_SIO_STAT_RX_NOT_EMPTY),
	branch_ne(R_T0, R_0, atom_offset(wait_ack3_port0, ack3_received_port0)),
	add_ui_self(R_T1, -1),
atom_label(continue_wait_ack3_port0)
	branch_ne(R_T1, R_0, atom_offset(continue_wait_ack3_port0, wait_ack3_port0)),
	mac_pad_sio_write_pad_state(PadSioStatus_Disconnected, R_PadState, R_T0),
atom_label(skip_port0_from_ack3)
	branch_equal(R_0, R_0, atom_offset(skip_port0_from_ack3, port1_start)),

atom_label(ack3_received_port0)
	load_byte_u(R_T0, R_PadSioBase, pad_SIO_DATA_OFFSET),

	/* Bounded by pad_SIO_WAIT_BUDGET = 4096 iterations. */
	add_ui(R_T1, R_0, pad_SIO_WAIT_BUDGET),
atom_label(wait_ackrel3_port0)
	load_half_u(R_T0, R_PadSioBase, pad_SIO_STAT_OFFSET),
	nop,
	and_i(R_T0, R_T0, pad_SIO_STAT_RX_NOT_EMPTY),
	branch_equal(R_T0, R_0, atom_offset(wait_ackrel3_port0, ack_released3_port0)),
	add_ui_self(R_T1, -1),
atom_label(continue_wait_ackrel3_port0)
	branch_ne(R_T1, R_0, atom_offset(continue_wait_ackrel3_port0, wait_ackrel3_port0)),
	mac_pad_sio_write_pad_state(PadSioStatus_Disconnected, R_PadState, R_T0),
atom_label(skip_port0_from_ackrel3)
	branch_equal(R_0, R_0, atom_offset(skip_port0_from_ackrel3, port1_start)),

atom_label(ack_released3_port0)

	/* === Byte 4 (FINAL, port 0): send 0x00 + RX-not-empty wait + read final byte === */
	/* Bounded by pad_SIO_WAIT_BUDGET = 4096 iterations. */
	add_ui(R_T0, R_0, 0x00),
	store_byte(R_T0, R_PadSioBase, pad_SIO_DATA_OFFSET),
	add_ui(R_T1, R_0, pad_SIO_WAIT_BUDGET),
atom_label(wait_rx4_port0)
	load_half_u(R_T0, R_PadSioBase, pad_SIO_STAT_OFFSET),
	nop,
	and_i(R_T0, R_T0, pad_SIO_STAT_RX_NOT_EMPTY),
	branch_ne(R_T0, R_0, atom_offset(wait_rx4_port0, rx4_received_port0)),
	add_ui_self(R_T1, -1),
atom_label(continue_wait_rx4_port0)
	branch_ne(R_T1, R_0, atom_offset(continue_wait_rx4_port0, wait_rx4_port0)),
	mac_pad_sio_write_pad_state(PadSioStatus_Disconnected, R_PadState, R_T0),
atom_label(skip_port0_from_rx4)
	branch_equal(R_0, R_0, atom_offset(skip_port0_from_rx4, port1_start)),

atom_label(rx4_received_port0)
	load_byte_u(R_T0, R_PadSioBase, pad_SIO_DATA_OFFSET),  /* discard final byte */

	/* === RESPONSE DECODE (hardcoded for teaching scope) ===
	 * Per the plan §"Phase 3 task 3.1" + spec §"Architecture":
	 *   - Full decode (buttons/axes from response bytes) is follow-up scope.
	 *   - Teaching scope: hardcode digital poll response.
	 *     status = PadSioStatus_Digital
	 *     buttons = 0x0000FFFF (no buttons pressed — placeholder)
	 *     axes = 0x80808080 (left_x=0x80, left_y=0x80, right_x=0x80, right_y=0x80)
	 *     attempt = 0
	 */
atom_label(decode_port0)
	mac_pad_sio_write_pad_state(PadSioStatus_Digital, R_PadState, R_T0),

	/* /CS cleanup: raise /CS, clear stale status before exiting port 0. */
	add_ui(R_T0, R_0, pad_SIO_CTRL_CLEANUP),
	store_half(R_T0, R_PadSioBase, pad_SIO_CTRL_OFFSET),

	/* ============== PORT 1 SETUP ============== */
	/* Swap: R_PadCountdown holds sio_base_addr1; R_PadStatus holds state1. */
atom_label(port1_start)
	add_u(R_PadSioBase, R_0, R_PadCountdown),  /* sio_base_addr1 → R_PadSioBase */
	add_u(R_PadState,   R_0, R_PadStatus),     /* state1 → R_PadState */

	/* ============== PORT 1 TRANSACTION (mirror of port 0) ============== */
	/* R_PadStatus + R_PadCountdown are no longer reserved (port 1 is the
	 * last transaction); we still use R_T0/R_T1 as scratch to match port 0. */

	/* 1. Cleanup: CTRL = 0x0010 (raise /CS, clear stale status) */
	add_ui(R_T0, R_0, pad_SIO_CTRL_CLEANUP),
	store_half(R_T0, R_PadSioBase, pad_SIO_CTRL_OFFSET),
	/* Bounded by pad_SIO_SETTLE_BEFORE_TX = 1000 iterations. */
	add_ui(R_T1, R_0, pad_SIO_SETTLE_BEFORE_TX),
atom_label(settle_pre_port1)
	nop,
	add_ui_self(R_T1, -1),
	branch_ne(R_T1, R_0, atom_offset(settle_pre_port1, settle_pre_port1)),

	/* 2. Port-select: CTRL = 0x0003 | (1 << 13) (port 1 select) */
	add_ui(R_T0, R_0, pad_SIO_CTRL_TX_ENABLE),
	or_i(R_T0, R_T0, pad_SIO_CTRL_DTR_CS),
	or_i(R_T0, R_T0, 1 << 13),  /* port 1 select bit (CTRL bit 13 = port select) */
	store_half(R_T0, R_PadSioBase, pad_SIO_CTRL_OFFSET),
	/* Bounded by pad_SIO_SETTLE_AFTER_TX = 2000 iterations. */
	add_ui(R_T1, R_0, pad_SIO_SETTLE_AFTER_TX),
atom_label(settle_post_port1)
	nop,
	add_ui_self(R_T1, -1),
	branch_ne(R_T1, R_0, atom_offset(settle_post_port1, settle_post_port1)),

	/* 3. Address byte (0x01) — send + RX-ready wait + read response + RX-drain confirmation */
	add_ui(R_T0, R_0, pad_PROTO_ADDR),
	store_byte(R_T0, R_PadSioBase, pad_SIO_DATA_OFFSET),

	/* Bounded by pad_SIO_WAIT_BUDGET = 4096 iterations. */
	add_ui(R_T1, R_0, pad_SIO_WAIT_BUDGET),
atom_label(wait_ack0_port1)
	load_half_u(R_T0, R_PadSioBase, pad_SIO_STAT_OFFSET),
	nop,
	and_i(R_T0, R_T0, pad_SIO_STAT_RX_NOT_EMPTY),
	branch_ne(R_T0, R_0, atom_offset(wait_ack0_port1, ack0_received_port1)),
	add_ui_self(R_T1, -1),
atom_label(continue_wait_ack0_port1)
	branch_ne(R_T1, R_0, atom_offset(continue_wait_ack0_port1, wait_ack0_port1)),
	mac_pad_sio_write_pad_state(PadSioStatus_Disconnected, R_PadState, R_T0),
atom_label(skip_port1_from_ack0)
	branch_equal(R_0, R_0, atom_offset(skip_port1_from_ack0, end_atom)),

atom_label(ack0_received_port1)
	load_byte_u(R_T0, R_PadSioBase, pad_SIO_DATA_OFFSET),

	/* Bounded by pad_SIO_WAIT_BUDGET = 4096 iterations. */
	add_ui(R_T1, R_0, pad_SIO_WAIT_BUDGET),
atom_label(wait_ackrel0_port1)
	load_half_u(R_T0, R_PadSioBase, pad_SIO_STAT_OFFSET),
	nop,
	and_i(R_T0, R_T0, pad_SIO_STAT_RX_NOT_EMPTY),
	branch_equal(R_T0, R_0, atom_offset(wait_ackrel0_port1, ack_released_port1)),
	add_ui_self(R_T1, -1),
atom_label(continue_wait_ackrel0_port1)
	branch_ne(R_T1, R_0, atom_offset(continue_wait_ackrel0_port1, wait_ackrel0_port1)),
	mac_pad_sio_write_pad_state(PadSioStatus_Disconnected, R_PadState, R_T0),
atom_label(skip_port1_from_ackrel0)
	branch_equal(R_0, R_0, atom_offset(skip_port1_from_ackrel0, end_atom)),

atom_label(ack_released_port1)

	/* === Byte 1 (port 1): send 0x42 (cmd read) + RX-ready wait + read response + RX-drain confirmation === */
	/* Bounded by pad_SIO_WAIT_BUDGET = 4096 iterations. */
	add_ui(R_T0, R_0, pad_PROTO_CMD_READ),
	store_byte(R_T0, R_PadSioBase, pad_SIO_DATA_OFFSET),
	add_ui(R_T1, R_0, pad_SIO_WAIT_BUDGET),
atom_label(wait_ack1_port1)
	load_half_u(R_T0, R_PadSioBase, pad_SIO_STAT_OFFSET),
	nop,
	and_i(R_T0, R_T0, pad_SIO_STAT_RX_NOT_EMPTY),
	branch_ne(R_T0, R_0, atom_offset(wait_ack1_port1, ack1_received_port1)),
	add_ui_self(R_T1, -1),
atom_label(continue_wait_ack1_port1)
	branch_ne(R_T1, R_0, atom_offset(continue_wait_ack1_port1, wait_ack1_port1)),
	mac_pad_sio_write_pad_state(PadSioStatus_Disconnected, R_PadState, R_T0),
atom_label(skip_port1_from_ack1)
	branch_equal(R_0, R_0, atom_offset(skip_port1_from_ack1, end_atom)),

atom_label(ack1_received_port1)
	load_byte_u(R_T0, R_PadSioBase, pad_SIO_DATA_OFFSET),

	/* Bounded by pad_SIO_WAIT_BUDGET = 4096 iterations. */
	add_ui(R_T1, R_0, pad_SIO_WAIT_BUDGET),
atom_label(wait_ackrel1_port1)
	load_half_u(R_T0, R_PadSioBase, pad_SIO_STAT_OFFSET),
	nop,
	and_i(R_T0, R_T0, pad_SIO_STAT_RX_NOT_EMPTY),
	branch_equal(R_T0, R_0, atom_offset(wait_ackrel1_port1, ack_released1_port1)),
	add_ui_self(R_T1, -1),
atom_label(continue_wait_ackrel1_port1)
	branch_ne(R_T1, R_0, atom_offset(continue_wait_ackrel1_port1, wait_ackrel1_port1)),
	mac_pad_sio_write_pad_state(PadSioStatus_Disconnected, R_PadState, R_T0),
atom_label(skip_port1_from_ackrel1)
	branch_equal(R_0, R_0, atom_offset(skip_port1_from_ackrel1, end_atom)),

atom_label(ack_released1_port1)

	/* === Byte 2 (port 1): send 0x00 + RX-ready wait + read response + RX-drain confirmation === */
	/* Bounded by pad_SIO_WAIT_BUDGET = 4096 iterations. */
	add_ui(R_T0, R_0, 0x00),
	store_byte(R_T0, R_PadSioBase, pad_SIO_DATA_OFFSET),
	add_ui(R_T1, R_0, pad_SIO_WAIT_BUDGET),
atom_label(wait_ack2_port1)
	load_half_u(R_T0, R_PadSioBase, pad_SIO_STAT_OFFSET),
	nop,
	and_i(R_T0, R_T0, pad_SIO_STAT_RX_NOT_EMPTY),
	branch_ne(R_T0, R_0, atom_offset(wait_ack2_port1, ack2_received_port1)),
	add_ui_self(R_T1, -1),
atom_label(continue_wait_ack2_port1)
	branch_ne(R_T1, R_0, atom_offset(continue_wait_ack2_port1, wait_ack2_port1)),
	mac_pad_sio_write_pad_state(PadSioStatus_Disconnected, R_PadState, R_T0),
atom_label(skip_port1_from_ack2)
	branch_equal(R_0, R_0, atom_offset(skip_port1_from_ack2, end_atom)),

atom_label(ack2_received_port1)
	load_byte_u(R_T0, R_PadSioBase, pad_SIO_DATA_OFFSET),

	/* Bounded by pad_SIO_WAIT_BUDGET = 4096 iterations. */
	add_ui(R_T1, R_0, pad_SIO_WAIT_BUDGET),
atom_label(wait_ackrel2_port1)
	load_half_u(R_T0, R_PadSioBase, pad_SIO_STAT_OFFSET),
	nop,
	and_i(R_T0, R_T0, pad_SIO_STAT_RX_NOT_EMPTY),
	branch_equal(R_T0, R_0, atom_offset(wait_ackrel2_port1, ack_released2_port1)),
	add_ui_self(R_T1, -1),
atom_label(continue_wait_ackrel2_port1)
	branch_ne(R_T1, R_0, atom_offset(continue_wait_ackrel2_port1, wait_ackrel2_port1)),
	mac_pad_sio_write_pad_state(PadSioStatus_Disconnected, R_PadState, R_T0),
atom_label(skip_port1_from_ackrel2)
	branch_equal(R_0, R_0, atom_offset(skip_port1_from_ackrel2, end_atom)),

atom_label(ack_released2_port1)

	/* === Byte 3 (port 1): send 0x00 + RX-ready wait + read response + RX-drain confirmation === */
	/* Bounded by pad_SIO_WAIT_BUDGET = 4096 iterations. */
	add_ui(R_T0, R_0, 0x00),
	store_byte(R_T0, R_PadSioBase, pad_SIO_DATA_OFFSET),
	add_ui(R_T1, R_0, pad_SIO_WAIT_BUDGET),
atom_label(wait_ack3_port1)
	load_half_u(R_T0, R_PadSioBase, pad_SIO_STAT_OFFSET),
	nop,
	and_i(R_T0, R_T0, pad_SIO_STAT_RX_NOT_EMPTY),
	branch_ne(R_T0, R_0, atom_offset(wait_ack3_port1, ack3_received_port1)),
	add_ui_self(R_T1, -1),
atom_label(continue_wait_ack3_port1)
	branch_ne(R_T1, R_0, atom_offset(continue_wait_ack3_port1, wait_ack3_port1)),
	mac_pad_sio_write_pad_state(PadSioStatus_Disconnected, R_PadState, R_T0),
atom_label(skip_port1_from_ack3)
	branch_equal(R_0, R_0, atom_offset(skip_port1_from_ack3, end_atom)),

atom_label(ack3_received_port1)
	load_byte_u(R_T0, R_PadSioBase, pad_SIO_DATA_OFFSET),

	/* Bounded by pad_SIO_WAIT_BUDGET = 4096 iterations. */
	add_ui(R_T1, R_0, pad_SIO_WAIT_BUDGET),
atom_label(wait_ackrel3_port1)
	load_half_u(R_T0, R_PadSioBase, pad_SIO_STAT_OFFSET),
	nop,
	and_i(R_T0, R_T0, pad_SIO_STAT_RX_NOT_EMPTY),
	branch_equal(R_T0, R_0, atom_offset(wait_ackrel3_port1, ack_released3_port1)),
	add_ui_self(R_T1, -1),
atom_label(continue_wait_ackrel3_port1)
	branch_ne(R_T1, R_0, atom_offset(continue_wait_ackrel3_port1, wait_ackrel3_port1)),
	mac_pad_sio_write_pad_state(PadSioStatus_Disconnected, R_PadState, R_T0),
atom_label(skip_port1_from_ackrel3)
	branch_equal(R_0, R_0, atom_offset(skip_port1_from_ackrel3, end_atom)),

atom_label(ack_released3_port1)

	/* === Byte 4 (FINAL, port 1): send 0x00 + RX-not-empty wait + read final byte === */
	/* Bounded by pad_SIO_WAIT_BUDGET = 4096 iterations. */
	add_ui(R_T0, R_0, 0x00),
	store_byte(R_T0, R_PadSioBase, pad_SIO_DATA_OFFSET),
	add_ui(R_T1, R_0, pad_SIO_WAIT_BUDGET),
atom_label(wait_rx4_port1)
	load_half_u(R_T0, R_PadSioBase, pad_SIO_STAT_OFFSET),
	nop,
	and_i(R_T0, R_T0, pad_SIO_STAT_RX_NOT_EMPTY),
	branch_ne(R_T0, R_0, atom_offset(wait_rx4_port1, rx4_received_port1)),
	add_ui_self(R_T1, -1),
atom_label(continue_wait_rx4_port1)
	branch_ne(R_T1, R_0, atom_offset(continue_wait_rx4_port1, wait_rx4_port1)),
	mac_pad_sio_write_pad_state(PadSioStatus_Disconnected, R_PadState, R_T0),
atom_label(skip_port1_from_rx4)
	branch_equal(R_0, R_0, atom_offset(skip_port1_from_rx4, end_atom)),

atom_label(rx4_received_port1)
	load_byte_u(R_T0, R_PadSioBase, pad_SIO_DATA_OFFSET),  /* discard final byte */

	/* === RESPONSE DECODE (port 1) === */
atom_label(decode_port1)
	mac_pad_sio_write_pad_state(PadSioStatus_Digital, R_PadState, R_T0),

	/* /CS cleanup: raise /CS, clear stale status before exiting port 1. */
	add_ui(R_T0, R_0, pad_SIO_CTRL_CLEANUP),
	store_half(R_T0, R_PadSioBase, pad_SIO_CTRL_OFFSET),

atom_label(end_atom)
	mac_yield(),
};

/* ----- pad_apply_input -----
 * Reads pad[0].buttons + pad[0].left_x; applies the input-semantics
 * deltas to cube_rot.y + floor_rot.y per spec §"Input semantics":
 *   - D-pad Left:  cube_rot.y += 30, floor_rot.y += 5
 *   - D-pad Right: cube_rot.y -= 30, floor_rot.y -= 5
 *   - Analog stick X (dead zone 0x70..0x90):
 *       cube delta  = (0x80 - left_x) >> 2  (range approx -32..+32)
 *       floor delta = (0x80 - left_x) >> 5  (range approx -4..+4)
 *   - D-pad + analog deltas add when used together.
 *
 * Convention (per spec line 137 + Task 3.1b buttons-fix):
 *   pad_state = 0 means no buttons active. The fail-safe zero-button
 *   value flows through unchanged, so a disconnected/fresh pad
 *   produces no rotation. The branch_le_zero pattern below matches
 *   the existing pad_input_demo convention (atom body lines 248/257).
 *
 * Signed-delta trick: load_byte_u zero-extends left_x to 32 bits; sub_u
 * from 0x80 wraps to a SIGNED two's-complement value in the negative
 * range; shift_aright (sra) then correctly sign-extends the shift for
 * both positive (left_x < 0x80) and negative (left_x > 0x80) cases.
 * Digital pads publish left_x = 0x80 → delta = 0 → no rotation, so the
 * analog step is naturally a no-op for digital controllers.
 */
internal MipsAtom_(pad_apply_input) atom_info(atom_bind(Binds_PadApplyInput)
, atom_reads(R_T0, R_T1, R_T2, R_T3, R_T4, R_T5, R_TapePtr)
, atom_writes(R_T1, R_T2)
) {
	/* Pop Binds from tape (state, cube_rot, floor_rot) */
	load_word(R_T5, R_TapePtr, O_(Binds_PadApplyInput,state)),
	load_word(R_T1, R_TapePtr, O_(Binds_PadApplyInput,cube_rot)),
	load_word(R_T2, R_TapePtr, O_(Binds_PadApplyInput,floor_rot)),
	add_ui_self(R_TapePtr, S_(Binds_PadApplyInput)),

	/* Load pad[0].buttons into R_T0. The following nop retires the MIPS-I
	 * load delay before the first and_i consumes R_T0. */
	load_word(R_T0, R_T5, O_(PadState,buttons)),
	nop,

	/* D-pad Left: cube_rot.y += 30, floor_rot.y += 5.
	 * branch_le_zero SKIPS the apply block when the button bit is
	 * NOT set in R_T0 (matches pad_input_demo convention). */
	and_i(R_T3, R_T0, pad0_(Pad_Left)),
	branch_le_zero(R_T3, atom_offset(dpad_left, exit_dpad_left)),
		load_half( R_T4, R_T1, O_(V3_S2,y)),   /* BD-slot */
		load_half( R_T3, R_T2, O_(V3_S2,y)),
		add_si(    R_T4, R_T4, 30),
		add_si(    R_T3, R_T3, 5),
		store_half(R_T4, R_T1, O_(V3_S2,y)),
		store_half(R_T3, R_T2, O_(V3_S2,y)),
	atom_label(exit_dpad_left)

	/* D-pad Right: cube_rot.y -= 30, floor_rot.y -= 5. */
	and_i(R_T3, R_T0, pad0_(Pad_Right)),
	branch_le_zero(R_T3, atom_offset(dpad_right, exit_dpad_right)),
		load_half( R_T4, R_T1, O_(V3_S2,y)),   /* BD-slot */
		load_half( R_T3, R_T2, O_(V3_S2,y)),
		add_si(    R_T4, R_T4, -30),
		add_si(    R_T3, R_T3, -5),
		store_half(R_T4, R_T1, O_(V3_S2,y)),
		store_half(R_T3, R_T2, O_(V3_S2,y)),
	atom_label(exit_dpad_right)

	/* Analog left-stick X: dead zone 0x70..0x90 (per spec line 89).
	 * Cube delta = (0x80 - left_x) >> 2; floor delta = (0x80 - left_x) >> 5. */
	load_byte_u(R_T3, R_T5, O_(PadState,left_x)),

	/* Dead-zone check: skip analog if left_x in [0x70, 0x90] inclusive.
	 * Outside dead zone on LOW side: left_x < 0x70 (strictly).
	 * set_lt_u(R_T4, R_T3, R_T4=0x70) → R_T4 = (left_x < 0x70) ? 1 : 0. */
	add_ui(R_T4, R_0, 0x70),
	set_lt_u(R_T4, R_T3, R_T4),
	branch_ne(R_T4, R_0, atom_offset(dead_zone_low_check, dead_low_active)),
		add_ui(R_T4, R_0, 0x80),   /* BD-slot: pre-load 0x80 for dead_low_active */

atom_label(dead_check_upper)
	/* left_x >= 0x70 → check upper bound. */
	load_byte_u(R_T3, R_T5, O_(PadState,left_x)),    /* reload */
	add_ui(R_T4, R_0, 0x90),
	set_lt_u(R_T4, R_T4, R_T3),    /* R_T4 = (0x90 < left_x) ? 1 : 0 → (left_x > 0x90) ? 1 : 0 */
	branch_ne(R_T4, R_0, atom_offset(dead_zone_high_check, dead_high_active)),
		add_ui(R_T4, R_0, 0x80),   /* BD-slot: pre-load 0x80 for dead_high_active */
	/* Fall-through = left_x in [0x70, 0x90] (dead zone); skip analog entirely. */
	branch_equal(R_0, R_0, atom_offset(dead_zone_skip, exit_stick)),
		nop,

atom_label(dead_low_active)
	/* R_T4 = 0x80 (from first BD-slot). delta = 0x80 - left_x (positive). */
	load_byte_u(R_T3, R_T5, O_(PadState,left_x)),
	sub_u(R_T3, R_T4, R_T3),                          /* R_T3 = 0x80 - left_x */
	shift_aright(R_T4, R_T3, 2),                      /* R_T4 = cube_delta */
	load_half(R_T0, R_T1, O_(V3_S2,y)),
	add_u(R_T0, R_T0, R_T4),
	store_half(R_T0, R_T1, O_(V3_S2,y)),
	shift_aright(R_T4, R_T3, 5),                      /* R_T4 = floor_delta */
	load_half(R_T0, R_T2, O_(V3_S2,y)),
	add_u(R_T0, R_T0, R_T4),
	store_half(R_T0, R_T2, O_(V3_S2,y)),
	branch_equal(R_0, R_0, atom_offset(end_low, exit_stick)),
		nop,

atom_label(dead_high_active)
	/* R_T4 = 0x80 (from second BD-slot). delta = 0x80 - left_x (signed negative). */
	load_byte_u(R_T3, R_T5, O_(PadState,left_x)),
	sub_u(R_T3, R_T4, R_T3),
	shift_aright(R_T4, R_T3, 2),                      /* R_T4 = cube_delta (signed) */
	load_half(R_T0, R_T1, O_(V3_S2,y)),
	add_u(R_T0, R_T0, R_T4),
	store_half(R_T0, R_T1, O_(V3_S2,y)),
	shift_aright(R_T4, R_T3, 5),                      /* R_T4 = floor_delta (signed) */
	load_half(R_T0, R_T2, O_(V3_S2,y)),
	add_u(R_T0, R_T0, R_T4),
	store_half(R_T0, R_T2, O_(V3_S2,y)),
atom_label(exit_stick)

	mac_yield(),
};

/* ----- pad_sio_diag_pin -----
 * Per-frame diagnostic counter. The caller binds R_DiagPinScratch to
 * scratch_for_atom_diag_pin for temporary gdb verification.
 */
internal MipsAtom_(pad_sio_diag_pin) atom_info(atom_phase(pad_init)
, atom_reads(R_T0, R_T1, R_DiagPinScratch)
, atom_writes(R_T0, R_T1, R_DiagPinScratch)
) {
	/* FIX 2026-08-02: explicitly reload R_DiagPinScratch (R_T3 = $t3). Caller-saved
	 * per O32 ABI; the rgcc binding in main() does not survive tape_run. */
	load_upper_i(R_DiagPinScratch, 0x8001),
	or_i(R_DiagPinScratch, R_DiagPinScratch, 0xC800),

	/* High half = 0xD1A6; low half increments once per atom invocation. */
	load_word(R_T1, R_DiagPinScratch, 0),
	nop,
	add_ui(R_T1, R_T1, 1),
	and_i(R_T0, R_T1, 0xFFFF),
	load_upper_i(R_T1, 0xD1A6),
	or_i(R_T1, R_T1, 0),
	or(R_T1, R_T1, R_T0),
	store_word(R_T1, R_DiagPinScratch, 0),
	mac_yield(),
};

/* ----- pad_sio_diag_byte_exchange -----
 * Temporary two-byte wire probe: sends 0x01 and 0x42, then stores the
 * open-bus byte and response ID in scratch_for_atom_diag_pin.
 */
internal MipsAtom_(pad_sio_diag_byte_exchange) atom_info(atom_phase(pad_init)
, atom_reads(R_T0, R_T1, R_T2, R_PadSioBase, R_DiagPinScratch)
, atom_writes(R_T0, R_T1, R_T2, R_PadSioBase, R_DiagPinScratch)
) {
	/* FIX 2026-08-02: explicitly reload R_DiagPinScratch (R_T3 = $t3). Caller-saved
	 * per O32 ABI; the rgcc binding in main() does not survive tape_run. */
	load_upper_i(R_DiagPinScratch, 0x8001),
	or_i(R_DiagPinScratch, R_DiagPinScratch, 0xC800),

	/* FIX 2026-08-02: explicitly load KSEG1 base into R_PadSioBase (R_T6) at the
	 * top. The rgcc() binding in main() does NOT survive the tape_run call
	 * because R_T6 is caller-saved per the O32 ABI. */
	load_upper_i(R_PadSioBase, pad_IO_KSEG1_BASE >> 16),
	or_i(R_PadSioBase, R_PadSioBase, pad_IO_KSEG1_BASE & 0xFFFF),

	add_ui(R_T0, R_0, pad_SIO_CTRL_CLEANUP),
	store_half(R_T0, R_PadSioBase, pad_SIO_CTRL_OFFSET),
	add_ui(R_T0, R_0, pad_SIO_CTRL_TX_ENABLE),
	or_i(R_T0, R_T0, pad_SIO_CTRL_DTR_CS),
	store_half(R_T0, R_PadSioBase, pad_SIO_CTRL_OFFSET),

	add_ui(R_T0, R_0, pad_PROTO_ADDR),
	store_byte(R_T0, R_PadSioBase, pad_SIO_DATA_OFFSET),
	add_ui(R_T1, R_0, pad_SIO_WAIT_BUDGET),
atom_label(diag_wait_ack0)
	load_half_u(R_T0, R_PadSioBase, pad_SIO_STAT_OFFSET),
	nop,
	and_i(R_T0, R_T0, pad_SIO_STAT_RX_NOT_EMPTY),
	branch_ne(R_T0, R_0, atom_offset(diag_wait_ack0, diag_ack0_done)),
	add_ui_self(R_T1, -1),
	branch_ne(R_T1, R_0, atom_offset(diag_wait_ack0, diag_wait_ack0)),
	add_ui(R_T0, R_0, 0xDEADAC01),
	store_word(R_T0, R_DiagPinScratch, 0),
	branch_equal(R_0, R_0, atom_offset(diag_timeout_ack0, diag_timeout)),
atom_label(diag_ack0_done)
	load_byte_u(R_T2, R_PadSioBase, pad_SIO_DATA_OFFSET),
	add_ui(R_T0, R_0, pad_PROTO_CMD_READ),
	store_byte(R_T0, R_PadSioBase, pad_SIO_DATA_OFFSET),
	add_ui(R_T1, R_0, pad_SIO_WAIT_BUDGET),
atom_label(diag_wait_ack1)
	load_half_u(R_T0, R_PadSioBase, pad_SIO_STAT_OFFSET),
	nop,
	and_i(R_T0, R_T0, pad_SIO_STAT_RX_NOT_EMPTY),
	branch_ne(R_T0, R_0, atom_offset(diag_wait_ack1, diag_ack1_done)),
	add_ui_self(R_T1, -1),
	branch_ne(R_T1, R_0, atom_offset(diag_wait_ack1, diag_wait_ack1)),
	add_ui(R_T0, R_0, 0xDEADAC02),
	store_word(R_T0, R_DiagPinScratch, 0),
	branch_equal(R_0, R_0, atom_offset(diag_timeout_ack1, diag_timeout)),
atom_label(diag_ack1_done)
	load_byte_u(R_T0, R_PadSioBase, pad_SIO_DATA_OFFSET),
	nop,
	shift_lleft(R_T0, R_T0, 8),
	or(R_T2, R_T2, R_T0),
	store_word(R_T2, R_DiagPinScratch, 0),
atom_label(diag_success)
	branch_equal(R_0, R_0, atom_offset(diag_success, diag_done)),
	nop,
atom_label(diag_timeout_ack0)
	add_ui(R_T0, R_0, 0xDEADAC01),
	store_word(R_T0, R_DiagPinScratch, 0),
atom_label(diag_timeout_ack1)
	add_ui(R_T0, R_0, 0xDEADAC02),
	store_word(R_T0, R_DiagPinScratch, 0),
atom_label(diag_timeout)
	add_ui(R_T0, R_0, 0xDEADACFF),
	store_word(R_T0, R_DiagPinScratch, 0),
atom_label(diag_done)
	add_ui(R_T0, R_0, pad_SIO_CTRL_CLEANUP),
	store_half(R_T0, R_PadSioBase, pad_SIO_CTRL_OFFSET),
	mac_yield(),
};

#pragma endregion Baked Atoms
