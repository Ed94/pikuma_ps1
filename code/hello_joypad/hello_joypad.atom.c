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
#	include "duffle/math.atom.c"
#	include "duffle/mips.atom.c"
#	include "duffle/gte.atom.c"
#	include "duffle/gp.atom.c"
#	include "duffle/psyq.atom.c"
#		include "gen/offsets.h"
#		include "gen/macs.h"
#	include "hello_joypad.h"
#endif

ATOM_FILE_DEBUGGER_LINE_MARKER(hello_joypad_atom_c);

#pragma region MACs (Mips Atom components)

FI_ Slice_MipsCode ac_put_disp_env(MipsAtomBuilder_R ab, U4 reg_transfer, U4 reg_base, U2 port)
MipsAtomComp_Proc_(ab, {
	// Emits 5 GP0 commands for buffer 0 (display_area = (0,0,320,240)).
	// Sequence per libpsyx PutDispEnv: DrawArea TL → DrawArea BR → Mask → DrawArea TL → DrawArea BR
	mac_gcmd_push(gp0_word_draw_area_top_left_origin,      reg_transfer, reg_base, port),
	mac_gcmd_push(gp0_word_draw_area_bottom_right_320x240, reg_transfer, reg_base, port),
	mac_gcmd_push(gp0_word_set_mask_bit(),                 reg_transfer, reg_base, port),
	mac_gcmd_push(gp0_word_draw_area_top_left_origin,      reg_transfer, reg_base, port),
	mac_gcmd_push(gp0_word_draw_area_bottom_right_320x240, reg_transfer, reg_base, port),
})

FI_ Slice_MipsCode ac_put_draw_env(MipsAtomBuilder_R ab, U4 reg_transfer, U4 reg_base, U2 port)
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
	mac_store_v2s2(R_0, R_ScreenY,                       R_ScreenBuf, O_(DrawEnv,drawing_offset[0]) + OA_(DoubleBuffer,draw,0)), /* draw[0].drawing_offset[0] = (0, 240); C11 passes y_arg as ofs. */

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
	R_PrimCursor = R_T7 atom_reg atom_type(U4*),    /* VRAM output cursor (primitive buffer) */
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

	mac_gte_load_tri_verts(R_VertBase, R_T0, R_T1, R_T2),
	nop2, gte_cmdw_rotate_translate_perspective_triple, // required cpu -> gte delay slot
	gte_cmdw_nclip,

	gte_mv_from_data_r(R_T0, C2_MAC0), nop,
	branch_le_zero(R_T0, atom_offset(cull, cube_g4_face_exit)),
		/* BD-slot: write the prim tag (R_0=0; overwrites the legacy tag word in the prim_buffer).
		 * If branch IS taken (face culled), the body is skipped and this 0-tag is stranded —
		 * harmless because the OT entry that points to this prim is created later, only on the body path. */
		store_word(R_0, R_PrimCursor, O_(Poly_G4, tag)),
		shift_lleft(R_AT, R_T3, v3s2_byteoff), add_u(R_AT, R_AT, R_VertBase),
		load_word(R_V0, R_AT, O_(V3_S2, x)),   load_word(R_V1, R_AT, O_(V3_S2, z)),
		gte_mv_to_data_r(R_V0, C2_VXY0),       gte_mv_to_data_r(R_V1, C2_VZ0),

		mac_gte_store_g4_p012(R_PrimCursor),
		gte_cmdw_rotate_translate_perspective_single,
		mac_gte_store_g4_p3(R_PrimCursor),

		gte_cmdw_avg_sort_z4,
		gte_mv_from_data_r(R_T1, C2_OTZ),
		add_ui(      R_AT, R_0,  OrderingTbl_Len),
		set_lt_u(    R_AT, R_T1, R_AT),

		branch_equal(R_AT, R_0,  atom_offset(bounds_chk, cube_g4_face_exit)), nop,
			mac_insert_ot_tag_g4(R_OtBase, R_PrimCursor),
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
	mac_load_tri_indices(R_FaceCursor, R_T0, R_T1, R_T2),
	mac_gte_load_tri_verts(R_VertBase,   R_T0, R_T1, R_T2),
	nop2, gte_cmdw_rotate_translate_perspective_triple, // 2 nops retire the final cpu -> gte writes before RTPT
	gte_cmdw_nclip,

	/* Culling (Branch forward if Backface) */
	gte_mv_from_data_r(R_T0, C2_MAC0),
	nop, branch_le_zero(R_T0, atom_offset(culling, floor_f3_face_exit)), nop, // required gte -> cpu load-delay slot.
		/* Format Primitive */
		mac_gte_store_f3(R_PrimCursor),

		/* Calculate Depth */
		gte_avg_sort_z3,
		gte_mv_from_data_r(R_T1, C2_OTZ),
		/* Bounds Check OTZ < 2048 (Branch forward to skip insertion) */
		add_ui(      R_AT, R_0,  OrderingTbl_Len),
		set_lt_u(    R_AT, R_T1, R_AT),
		branch_equal(R_AT, R_0,  atom_offset(bounds_chk, floor_f3_face_exit)), nop,
			mac_format_f3_color(R_PrimCursor, 0xFF, 0xFF, 0xFF),  // RGB-form (R=FF, G=FF, B=FF = white)
			mac_insert_ot_tag_f3(R_OtBase, R_PrimCursor),         /* Insert into Ordering Table Linked List */
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

/* ----- pad_bios_snapshot -----
 * Per-frame snapshot of one BIOS pad buffer into PadState.
 * Decoder (branch ladder on raw[0] status + raw[1] id):
 *   1. raw[0] == 0xFF         -> Disconnected (buttons=0, axes=0x80)
 *   2. raw[0]==0 && raw[1]==0 -> Pending      (buttons=0, axes=0x80)
 *   3. raw[1] == 0x41         -> Digital      (buttons normalized; axes=0x80)
 *   4. raw[1] == 0x53         -> AnalogStick  (buttons normalized; axes from raw[4..7])
 *   5. raw[1] in 0x7x         -> AnalogPad    (buttons normalized; axes from raw[4..7])
 *   6. else                   -> Unsupported  (buttons=0, axes=0x80)
 *
 * Buttons normalization: byte_swap16((~raw_buttons) & 0xFFFF).
 *   raw_buttons    = load_half_u(raw, 2) = raw[2] | (raw[3] << 8).
 *   byte_swap16(x) = (x >> 8) | (x << 8); nor(x, R_0) = ~x. store_half truncates to 16 bits so the upper-16 mask is implicit in the store.
 *
 * Register use (atom-local; no wave-context touched):
 *   R_T0 = raw base      (kept throughout; axes loads read raw[4..7] from R_T0)
 *   R_T1 = state base    (kept throughout; all stores go through R_T1)
 *   R_T2 = raw[0] status (alive across the disc/pending/id dispatch, then dead)
 *   R_T3 = raw[1] id     (alive across the id dispatch, then dead)
 *   R_T4 = scratch       (shifts, compares, immediate loads, store values)
 *   R_T5 = scratch       (parallel lui+ori for the 0x80808080 axes constant + byte-swap target)
 */
enum {
	R_PadRaw    = R_T0 atom_reg atom_type(U1),
	R_PadState  = R_T1 atom_reg,
	R_RawStatus = R_T2 atom_reg,
	R_RawId     = R_T3 atom_reg,
};
typedef Struct_(Binds_PadBiosSnapshot) {
    PadBiosRaw* raw;
    PadState*   state;
};
internal MipsAtom_(pad_bios_snapshot) atom_info(atom_bind(Binds_PadBiosSnapshot)
, atom_reads( R_PadRaw, R_PadState, R_RawStatus, R_RawId, R_T4, R_T5, R_TapePtr)
, atom_writes(R_PadRaw, R_PadState, R_RawStatus, R_RawId, R_T4, R_T5, R_TapePtr)
) {
	/* === Bind consumption: T0 = raw, T1 = state, advance R_TapePtr by 8. */
	load_word(R_PadRaw,   R_TapePtr, O_(Binds_PadBiosSnapshot,raw)),
	load_word(R_PadState, R_TapePtr, O_(Binds_PadBiosSnapshot,state)),
	add_ui_self(          R_TapePtr, S_(Binds_PadBiosSnapshot)),

	/* === Read raw[0] (status) + raw[1] (id) */
	load_byte_u(R_RawStatus, R_PadRaw, 0),
	load_byte_u(R_RawId,     R_PadRaw, 1),

atom_label(snap_root) /* === Case 1: Disconnected (status == 0xFF). */
	add_ui(R_T4, R_0, 0xFF), branch_ne(R_RawStatus, R_T4, atom_offset(snap_root, skip_disconnected)),
	/* BD-slot: pre-compute PadStatus_Disconnected. Branch reads R_T4=0xFF in EX before this WB completes.
	 * If branch NOT taken (fall through to pending/id_dispatch), R_T4 is overwritten by the next case body's add_ui — harmless. */

atom_label(disconnected) /* === Disconnected body. */
	/* R_T4 = PadStatus_Disconnected from snap_root BD-slot. */
	store_word(R_T4, R_PadState, O_(PadState,status)),
	store_half(R_0,  R_PadState, O_(PadState,buttons)),
	/* axes = 0x80808080 (centered) — single sw writes the 4-byte axes block at offset 8 (left_x, left_y, right_x, right_y). */
	load_upper_i(R_T4, 0x8080), or_i_self(R_T4, 0x8080),
	store_word(  R_T4,    R_PadState, O_(PadState,left_x)),
	store_byte(  R_RawId, R_PadState, O_(PadState,id)),
	jump_rel(atom_offset(disconnected, snap_end)),
		/* BD-slot: load next atom's entry point (replaces the nop).
		 * The unconditional branch always jumps to snap_end, where mac_yield_tail()
		 * transfers control to R_AtomJmp without re-loading it. */
		mac_yield_load(),
atom_label(skip_disconnected)

	/* === Case 2: Pending (status == 0 && id == 0)
	 * Combined check: if (status | id) != 0 then skip to id_dispatch.
	 * Falls through to the Pending case only when both are zero. */
	or_u_self(R_RawStatus, R_RawId), branch_ne(R_RawStatus, R_0, atom_offset(case_2, id_dispatch)),
	/* BD-slot: pre-compute PadStatus_Pending. Branch reads R_RawStatus in EX before this WB completes.
	 * If branch NOT taken (fall through to id_dispatch), R_T4 is overwritten by the digital/analog body add_ui — harmless. */

atom_label(pending) /* === Pending body */
	/* R_T4 = PadStatus_Pending from case_2 BD-slot. */
	store_word(R_T4, R_PadState, O_(PadState,status)),
	store_half(R_0,  R_PadState, O_(PadState,buttons)),
	/* axes = 0x80808080 (centered) — single sw writes the 4-byte axes block at offset 8 (left_x, left_y, right_x, right_y). */
	load_upper_i(R_T4, 0x8080), or_i_self(R_T4, 0x8080),
	store_word(  R_T4,    R_PadState, O_(PadState,left_x)),
	store_byte(  R_RawId, R_PadState, O_(PadState,id)),
	jump_rel(atom_offset(pending, snap_end)),
		mac_yield_load(),

atom_label(id_dispatch) /* === Case 3-6: ID dispatch */
	add_ui(R_T4, R_0, 0x41), branch_ne(R_RawId, R_T4, atom_offset(id_dispatch, try_analog_stick)),
	/* BD-slot: pre-compute PadStatus_Digital. Branch reads R_RawId in EX before this WB completes.
	 * If branch NOT taken (fall through to try_analog_stick), R_T4 is overwritten by the analog body add_ui. */

	/* === Digital body (status, buttons normalize, axes=0x80, id, branch. */
	/* R_T4 = PadStatus_Digital from id_dispatch BD-slot. */
	store_word( R_T4, R_PadState, O_(PadState,status)),
	load_half_u(R_T4, R_PadRaw,   2 * S_(U1)),
	/* Fill R_T4's load-delay slot with the 0x80808080 axes constant into R_T5
	 * (R_T5 is dead on this path; it's only consumed at the analog_pad range check). */
	load_upper_i(R_T5, 0x8080), or_i_self(R_T5, 0x8080),
	nor_u(      R_T4, R_T4, R_0), /* raw_buttons is already in host bit order; no swap needed */
	store_half( R_T4, R_PadState, O_(PadState,buttons)),

	/* axes = 0x80808080 (centered) — single sw writes the 4-byte axes block at offset 8 (left_x, left_y, right_x, right_y). */
	store_word(  R_T5, R_PadState, O_(PadState,left_x)),
	add_ui(      R_T4, R_0, 0x41),
	store_byte(  R_T4, R_PadState, O_(PadState,id)),

	jump_rel(atom_offset(id_dispatch, snap_end)),
		mac_yield_load(),

atom_label(try_analog_stick) /* === Case 4: AnalogStick (id == 0x53)*/
	add_ui(R_T4, R_0, 0x53), branch_ne(R_RawId, R_T4, atom_offset(try_analog_stick, try_analog_pad)),
	/* BD-slot: pre-compute PadStatus_AnalogStick. Branch reads R_RawId in EX before this WB completes.
	 * If branch NOT taken (fall through to try_analog_pad), R_T4 is overwritten by the analog_pad body add_ui. */

atom_label(analog_stick) /* === AnalogStick body
	* Axes are loaded as two halfwords: raw[6..7] → left_xy (sh at offset 8), raw[4..5] → right_xy (sh at offset 10).
	* R_T5 holds left_xy / id-value in turn (it's dead on this path — only consumed at the analog_pad range check). */
	/* R_T4 = PadStatus_AnalogStick from try_analog_stick BD-slot. */
	store_word(  R_T4, R_PadState, O_(PadState,status)),
	load_half_u( R_T4, R_PadRaw,   2 * S_(U1)),           /* R_T4 = raw_buttons */
	load_half_u( R_T5, R_PadRaw,   6 * S_(U1)),           /* R_T5 = left_xy; fills R_T4's load-delay slot (doesn't read R_T4) */
	nor_u(       R_T4, R_T4, R_0),                        /* R_T4 = ~raw_buttons */
	store_half(  R_T4, R_PadState, O_(PadState,buttons)),
	load_half_u( R_T4, R_PadRaw,   4 * S_(U1)),           /* R_T4 = right_xy; fills R_T5's load-delay slot */
	store_half(  R_T5, R_PadState, O_(PadState,left_x)),  /* R_T5 settled, store left_xy */
	store_half(  R_T4, R_PadState, O_(PadState,right_x)),
	add_ui(      R_T5, R_0, 0x53),                        /* R_T5 = id value (clobbers left_xy, already stored) */
	store_byte(  R_T5, R_PadState, O_(PadState,id)),
	jump_rel(atom_offset(analog_stick, snap_end)),
		mac_yield_load(),

atom_label(try_analog_pad) /* === Case 5-6: AnalogPad (id & 0xF0 == 0x70) */
	and_i(    R_T4, R_RawId, 0xF0),
	add_ui(   R_T5, R_0,     0x70),
	branch_ne(R_T4, R_T5, atom_offset(try_analog_pad, try_unsupported)),
	/* BD-slot: pre-compute PadStatus_AnalogPad. Branch reads R_T4 in EX before this WB completes.
	 * If branch NOT taken (fall through to try_unsupported), R_T4 is overwritten by the unsupported body add_ui. */

atom_label(analog_pad) /* === AnalogPad body
	* Same shape as AnalogStick with AnalogPad status. R_T5 holds left_xy (it's dead on this path). */
	/* R_T4 = PadStatus_AnalogPad from try_analog_pad BD-slot. */
	store_word( R_T4, R_PadState, O_(PadState,status)),
	load_half_u(R_T4, R_PadRaw,   2 * S_(U1)),           /* R_T4 = raw_buttons */
	load_half_u(R_T5, R_PadRaw,   6 * S_(U1)),           /* R_T5 = left_xy; fills R_T4's load-delay slot */
	nor_u(      R_T4, R_T4, R_0),                        /* R_T4 = ~raw_buttons */
	store_half( R_T4, R_PadState, O_(PadState,buttons)),
	load_half_u(R_T4, R_PadRaw,   4 * S_(U1)),           /* R_T4 = right_xy; fills R_T5's load-delay slot */
	store_half( R_T5, R_PadState, O_(PadState,left_x)),  /* R_T5 settled, store left_xy */
	store_half( R_T4, R_PadState, O_(PadState,right_x)),
	store_byte( R_RawId, R_PadState, O_(PadState,id)),

	jump_rel(atom_offset(analog_pad, snap_end)),
		mac_yield_load(),

atom_label(try_unsupported) /* === Case 7: Unsupported — fall through from the AnalogPad range-check miss. */
	add_ui(    R_T4, R_0, PadStatus_Unsupported),
	store_word(R_T4, R_PadState, O_(PadState,status)),
	store_half(R_0,  R_PadState, O_(PadState,buttons)),
	/* axes = 0x80808080 (centered) — single sw writes the 4-byte axes block at offset 8 (left_x, left_y, right_x, right_y). */
	load_upper_i(R_T4, 0x8080), or_i_self(R_T4, 0x8080),
	store_word(  R_T4, R_PadState, O_(PadState,left_x)),
	add_ui(      R_T4, R_0, 0xFF),                      /* 0xFF sentinel: "unknown id" */
	store_byte(  R_T4, R_PadState, O_(PadState,id)),
	/* Fall through to snap_end. */

atom_label(no_jump_fallthrough)
	mac_yield_load(),

atom_label(snap_end)
	/* NOT mac_yield() — R_AtomJmp was already loaded in the BD-slot of the case-exit branch. */
	mac_yield_tail(),
};

/* ----- pad_apply_input -----
 * Reads pad[0].buttons + pad[0].left_x; 
 * Applies the input-semantics deltas to cube_rot.y + floor_rot.y:
 *   - D-pad Left:  cube_rot.y += 30, floor_rot.y += 5
 *   - D-pad Right: cube_rot.y -= 30, floor_rot.y -= 5
 *   - Analog stick X (dead zone 0x70..0x90):
 *       cube delta  = (0x80 - left_x) >> 2  (range approx -32..+32)
 *       floor delta = (0x80 - left_x) >> 5  (range approx -4..+4)
 *   - D-pad + analog deltas add when used together.
 *
 * Convention:
 *   pad_state = 0 means no buttons active. 
 *   The fail-safe zero-button value flows through unchanged, so a disconnected/fresh pad produces no rotation.
 *   The branch_le_zero pattern below matches the existing pad_input_demo convention (atom body lines 248/257).
 *
 * Signed-delta trick:
 * load_byte_u zero-extends left_x to 32 bits; sub_u from 0x80 wraps to a SIGNED two's-complement value in the negative range;
 * shift_aright (sra) then correctly sign-extends the shift for both positive (left_x < 0x80) and negative (left_x > 0x80) cases.
 * Digital pads publish left_x = 0x80 → delta = 0 → no rotation, so the analog step is naturally a no-op for digital controllers.
 */
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
internal MipsAtom_(pad_apply_input) atom_info(atom_bind(Binds_PadApplyInput)
, atom_reads(R_T0, R_CubeRot, R_FloorRot, R_T3, R_T4, R_PadStateT5, R_TapePtr)
, atom_writes(     R_CubeRot, R_FloorRot)
) {
	/* Pop Binds from tape (state, cube_rot, floor_rot) */
	load_word(R_PadStateT5, R_TapePtr, O_(Binds_PadApplyInput,state)),
	load_word(R_CubeRot,    R_TapePtr, O_(Binds_PadApplyInput,cube_rot)),
	load_word(R_FloorRot,   R_TapePtr, O_(Binds_PadApplyInput,floor_rot)),
	add_ui_self(            R_TapePtr, S_(Binds_PadApplyInput)),

	/* Load pad[0].buttons into R_T0. */
	load_word(R_T0, R_PadStateT5, O_(PadState,buttons)), nop,
	// Note(Ed): Potential op with delay slot?

	/* D-pad Left: cube_rot.y += 30, floor_rot.y += 5.  */
	and_i(R_T3, R_T0, pad0_(Pad_Left)), branch_le_zero(R_T3, atom_offset(dpad_left, exit_dpad_left)),
		load_half( R_T4, R_CubeRot,  O_(V3_S2,y)),   /* BD-slot */
		load_half( R_T3, R_FloorRot, O_(V3_S2,y)),
		add_si(    R_T4, R_T4, 30),
		add_si(    R_T3, R_T3, 5),
		store_half(R_T4, R_CubeRot,  O_(V3_S2,y)),
		store_half(R_T3, R_FloorRot, O_(V3_S2,y)),
	atom_label(exit_dpad_left)

	/* D-pad Right: cube_rot.y -= 30, floor_rot.y -= 5. */
	and_i(R_T3, R_T0, pad0_(Pad_Right)), branch_le_zero(R_T3, atom_offset(dpad_right, exit_dpad_right)),
		load_half( R_T4, R_CubeRot,  O_(V3_S2,y)),   /* BD-slot */
		load_half( R_T3, R_FloorRot, O_(V3_S2,y)),
		add_si(    R_T4, R_T4, -30),
		add_si(    R_T3, R_T3, -5),
		store_half(R_T4, R_CubeRot,  O_(V3_S2,y)),
		store_half(R_T3, R_FloorRot, O_(V3_S2,y)),
	atom_label(exit_dpad_right)

	/* Analog left-stick X: dead zone 0x70..0x90.
	 * Cube delta = (0x80 - left_x) >> 2; floor delta = (0x80 - left_x) >> 5. */
	load_byte_u(R_T3, R_PadStateT5, O_(PadState,left_x)),

	/* Dead-zone check: skip analog if left_x in [0x70, 0x90] inclusive. Outside dead zone on LOW side: left_x < 0x70 (strictly).
	 * set_lt_u(R_T4, R_T3, R_T4=0x70) → R_T4 = (left_x < 0x70) ? 1 : 0. */
	add_ui(R_T4, R_0, 0x70), set_lt_u(R_T4, R_T3, R_T4), branch_ne(R_T4, R_0, atom_offset(dead_zone_low_check, dead_low_active)),
	add_ui(R_T4, R_0, 0x80), /* BD-slot: pre-load 0x80 for dead_low_active */

atom_label(dead_check_upper)
	/* left_x >= 0x70 → check upper bound. */
	load_byte_u(R_T3, R_PadStateT5, O_(PadState,left_x)), /* reload */
	add_ui(     R_T4, R_0, 0x90),

	/* R_T4 = (0x90 < left_x) ? 1 : 0 → (left_x > 0x90) ? 1 : 0 */
	set_lt_u(R_T4, R_T4, R_T3), branch_ne(R_T4, R_0, atom_offset(dead_zone_high_check, dead_high_active)),
	add_ui(  R_T4, R_0, 0x80), /* BD-slot: pre-load 0x80 for dead_high_active */
	jump_rel(atom_offset(dead_zone_skip, exit_stick)),
		mac_yield_load(),

atom_label(dead_low_active)
	/* R_T3 = left_x (from line 632 lbu; not clobbered between dead_zone_low_check branch + its BD-slot `add_ui R_T4, 0x80`).
	 * The earlier `load_byte_u(R_T3, ...)` reload was redundant and introduced a load-use hazard on the next `sub_u`.
	 * R_T4 = 0x80 from the BD-slot of `dead_zone_low_check`'s branch_ne. */
	sub_u( R_T3, R_T4, R_T3), /* R_T3 = 0x80 - left_x */
	/* delta = 0x80 - left_x (positive). */

	/* R_T4 = cube_delta */
	shift_aright(R_T4, R_T3, 2),
	load_half(   R_T0, R_CubeRot, O_(V3_S2,y)),
	nop,
	add_u(       R_T0, R_T0, R_T4),
	store_half(  R_T0, R_CubeRot, O_(V3_S2,y)),
	/* R_T4 = floor_delta — moved into the load-delay slot of the floor load below (fills the 1-instruction gap;
	 * doesn't read R_T0; R_T4 settles by the subsequent add_u). */
	load_half(   R_T0, R_FloorRot, O_(V3_S2,y)),
	shift_aright(R_T4, R_T3, 5),
	add_u(       R_T0, R_T0, R_T4),
	store_half(  R_T0, R_FloorRot, O_(V3_S2,y)),

	jump_rel(atom_offset(end_low, exit_stick)),
		mac_yield_load(),

atom_label(dead_high_active)
	/* R_T3 = left_x (from line 641 lbu in dead_check_upper; not clobbered between dead_zone_high_check branch + its BD-slot `add_ui R_T4, 0x80`).
	 * The earlier `load_byte_u(R_T3, ...)` reload was redundant and introduced a load-use hazard on the next `sub_u`.
	 * R_T4 = 0x80 from the BD-slot of `dead_zone_high_check`'s branch_ne. */
	sub_u( R_T3, R_T4, R_T3),
	/* delta = 0x80 - left_x (signed negative). */

	shift_aright(R_T4, R_T3, 2),                      /* R_T4 = cube_delta (signed) */
	load_half(   R_T0, R_CubeRot, O_(V3_S2,y)),
	nop,
	add_u(       R_T0, R_T0, R_T4),
	store_half(  R_T0, R_CubeRot, O_(V3_S2,y)),

	/* R_T4 = floor_delta (signed) — moved into the load-delay slot of the floor load below. */
	load_half(   R_T0, R_FloorRot, O_(V3_S2,y)),
	shift_aright(R_T4, R_T3, 5),
	add_u(       R_T0, R_T0, R_T4),
	store_half(  R_T0, R_FloorRot, O_(V3_S2,y)),

atom_label(no_jump_fallthrough)
	mac_yield_load(),

atom_label(exit_stick)
	/* NOT mac_yield() — R_AtomJmp was already loaded in the BD-slot of the dead-zone/exit branch. */
	mac_yield_tail(),
};

#pragma endregion Baked Atoms
