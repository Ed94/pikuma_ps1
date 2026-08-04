#ifdef INTELLISENSE_DIRECTIVES
#	include "duffle/gen/duffle.macs.h"
#	include "duffle/gen/duffle.offsets.h"
#	include "duffle/atom_dsl.h"
#	include "duffle/lottes_tape.h"
#	include "duffle/word_count.metadata.h"
#	include "gen/hello_gte.offsets.h"
#	include "hello_gte.h"
#endif

#pragma region MACs (Mips Atom components)



#pragma endregion MACs

#pragma region Baked Atoms

/* DIAGNOSTIC 1: Pure tape loop test */
internal MipsAtom_(diag_yield) { mac_yield() };

/* DIAGNOSTIC 2: Pure memory test (No GTE). Draws a fixed cyan triangle. */
internal MipsAtom_(diag_color) {
	store_word(  R_0, R_T7, 0), 
	load_upper_i(R_AT, gp0_cmd_poly_f3 << 8 | 0xFF), /* High: MipsCode Poly_F3(0x20) + Color B:FF */
	or_i_self(   R_AT, 0xFF00),                      /* Low:  Color G:FF, R:00 (Cyan) */
	store_word(  R_AT, R_T7, 4),
	
	/* Fake coordinates - Swapped winding order to prevent GPU culling! */
	load_upper_i(R_AT, 0x0010), or_i_self(R_AT, 0x0010), store_word(R_AT, R_T7, 8),  /* (16, 16) */
	load_upper_i(R_AT, 0x0050), or_i_self(R_AT, 0x0010), store_word(R_AT, R_T7, 12), /* (80, 16) */
	load_upper_i(R_AT, 0x0010), or_i_self(R_AT, 0x0050), store_word(R_AT, R_T7, 16), /* (16, 80) */

	add_ui(          R_T1, R_0,  10),
	shift_lleft_self(R_T1,       S_(U4)/2), 
	add_u_self(      R_T1,       R_T6),         
	
	load_word(   R_AT, R_T1, 0),        
	load_upper_i(R_V0, (S_(Poly_F3)/S_(U4) - S_(PolyTag)/S_(U4)) << PolyTag_len_bits),
	store_word(  R_AT, R_T7, 0),       
	shift_lleft(R_AT, R_T7, S_(PolyTag_len_bits)), shift_lright(R_AT, R_AT, S_(PolyTag_len_bits)),         
	or_u_self(  R_AT, R_V0),          
	store_word( R_AT, R_T1, 0),       

	add_ui(R_T7, R_T7, 20),          

	mac_yield()
};

/* DIAGNOSTIC 3: Pure GTE test (No Memory Writes) */
internal MipsAtom_(diag_gte) {
	/* Load 3 indices */
	load_half_u(R_T0, R_T4, 0),
	load_half_u(R_T1, R_T4, 2),
	load_half_u(R_T2, R_T4, 4),

	/* Load Vertices into GTE */
	shift_lleft( R_AT, R_T0, 3), add_u(    R_AT, R_AT, R_T5),
	load_word(R_V0, R_AT, 0), load_word(R_V1, R_AT, 4),
	gte_mv_to_data_r(R_V0, C2_VXY0), gte_mv_to_data_r(R_V1, C2_VZ0),

	shift_lleft( R_AT, R_T1, 3), add_u(R_AT, R_AT, R_T5),
	load_word(R_V0, R_AT, 0), load_word(R_V1, R_AT, 4),
	gte_mv_to_data_r(R_V0, C2_VXY1), gte_mv_to_data_r(R_V1, C2_VZ1),

	shift_lleft(R_AT, R_T2, 3), add_u(R_AT, R_AT, R_T5),
	load_word(R_V0, R_AT, 0), load_word(R_V1, R_AT, 4),
	gte_mv_to_data_r(R_V0, C2_VXY2), gte_mv_to_data_r(R_V1, C2_VZ2),

	/* Run Math */
	nop2, gte_cmdw_rtpt,
	nop2, gte_cmdw_nclip,
	nop2,

	/* Advance Face Cursor and Yield */
	add_ui(R_T4, R_T4, 8),

	mac_yield()
};

typedef Struct_(Binds_CubeTri) {
	U4     PrimCursor;
	V4_S2* FaceCursor;
	V3_S2* VertBase;
	U4*    OtBase;
};
internal MipsAtom_(rbind_cube_g4_face) atom_info(atom_bind(Binds_CubeTri), atom_phase(cube_g4)
,	atom_reads(R_TapePtr)
,	atom_writes(R_PrimCursor, R_FaceCursor, R_VertBase, R_OtBase)
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

		add_ui(      R_AT, R_0, OrderingTbl_Len),
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
	, atom_writes(R_PrimCursor, R_FaceCursor, R_VertBase, R_OtBase)
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
		/* Bounds Check OTZ < OrderingTbl_Len (Branch forward to skip insertion) */
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
