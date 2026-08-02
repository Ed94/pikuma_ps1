#ifdef INTELLISENSE_DIRECTIVES
#	include "duffle/gen/duffle.macs.h"
#	include "duffle/gen/duffle.offsets.h"
#	include "duffle/atom_dsl.h"
#	include "duffle/pad.h"
#	include "duffle/lottes_tape.h"
#	include "duffle/mips.h"
#	include "duffle/gte.h"
#	include "duffle/gp.h"
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
	R_PadState  = R_T4 atom_reg atom_type(U4),
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
, atom_reads(R_PadState, R_CubeRot, R_FloorRot)
, atom_writes(R_CubeRot, R_FloorRot)
) {
	load_word(R_PadState, R_TapePtr, O_(Binds_PadInputDemo,pad_state)),
	load_word(R_CubeRot,  R_TapePtr, O_(Binds_PadInputDemo,cube_rot)),
	load_word(R_FloorRot, R_TapePtr, O_(Binds_PadInputDemo,floor_rot)),
	add_ui_self(          R_TapePtr, S_(Binds_PadInputDemo)),

	and_i(R_PadSignal, R_PadState, pad0_(Pad_Left)), branch_le_zero(R_PadSignal, atom_offset(pad_left, exit_pad_left)),
		load_half( R_T5, R_CubeRot,  O_(V3_S2,y)), // BD-Slot occupied
		load_half( R_T6, R_FloorRot, O_(V3_S2,y)),
		add_si(    R_T5, R_T5, 30),
		add_si(    R_T6, R_T6, 5),
		store_half(R_T5, R_CubeRot,  O_(V3_S2,y)),
		store_half(R_T6, R_FloorRot, O_(V3_S2,y)),
	atom_label(exit_pad_left)

	and_i(R_PadSignal, R_PadState, pad0_(Pad_Right)), branch_le_zero(R_PadSignal, atom_offset(pad_right, exit_pad_right)),
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

#pragma endregion Baked Atoms
