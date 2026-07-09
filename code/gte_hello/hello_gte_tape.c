#ifdef INTELLISENSE_DIRECTIVES
#	include "duffle/gen/duffle.macs.h"
#	include "duffle/gen/duffle.offsets.h"
#	include "duffle/atom_dsl.h"
#	include "duffle/lottes_tape.h"
#	include "tape_atom.metadata.h"
#	include "gen/gte_hello.offsets.h"
#	include "hello_gte.h"
#endif

#pragma region MACs (Mips Atom components)
/* The macros mac_format_f3_color and mac_gte_store_f3 moved to
 * lottes_tape.h during the Phase 3 gp.h overhaul. Both are now RGB-form
 * (mac_format_f3_color takes _r, _g, _b byte values rather than raw
 * 16-bit half-words). */

#pragma endregion MACs

#pragma region Baked Atoms

typedef Struct_(Binds_CubeTri) {
	U4     PrimCursor;
	V4_S2* FaceCursor;
	V3_S2* VertBase;
	U4*    OtBase;
};
internal MipsAtom_(rbind_cube_g4_face) {
	/* Pop 4 arguments from the tape directly into the workspace registers */
	load_word(R_PrimCursor, R_TapePtr, O_(Binds_CubeTri,PrimCursor)), 
	load_word(R_FaceCursor, R_TapePtr, O_(Binds_CubeTri,FaceCursor)), 
	load_word(R_VertBase,   R_TapePtr, O_(Binds_CubeTri,VertBase)), 
	load_word(R_OtBase,     R_TapePtr, O_(Binds_CubeTri,OtBase)), 
	add_ui_self(            R_TapePtr, S_(Binds_CubeTri)),
	// Note(Ed): This entire thing is argument shuffle?
	// TODO(Ed): Eliminate
	mac_yield()
};

/* ============================================================================
 *  cube_g4_face — Draw one cube face (Gouraud-shaded quad) via the GTE tape pipeline
 * ============================================================================
 *
 *  Reads 4 indices from R_FaceCur (V4_S2 = 8 bytes), loads 4 vertices into
 *  the GTE, runs the PsyQ RotAverageNclip4 sequence, and renders a Poly_G4.
 */
	atom_region  (cube_g4_face, REGION_PRIM_ARENA)
	atom_group   (cube_g4_face, GROUP_RENDER_PRIMS)
	atom_cadence (cube_g4_face, CADENCE_FRAME)
	atom_annot(cube_g4_face, phase_work,
			atom_reads( R_PrimCursor, R_FaceCursor, R_VertBase, R_OtBase),
			atom_writes(R_PrimCursor, R_FaceCursor))
internal 
MipsAtom_(cube_g4_face) {
	/* ── 1. Load 4 face indices from R_FaceCur (V4_S2 = 8 bytes) ───────── */
	load_half_u(R_T0, R_FaceCursor, 0 * S_(S2)),
	load_half_u(R_T1, R_FaceCursor, 1 * S_(S2)),
	load_half_u(R_T2, R_FaceCursor, 2 * S_(S2)),
	load_half_u(R_T3, R_FaceCursor, 3 * S_(S2)),

	/* ── 2. Load V0, V1, V2 into GTE (parallel to mac_load_tri_verts) ── */
	mac_load_tri_verts(R_T0, R_T1, R_T2),

	/* ── 3. RTPT — transforms V0/V1/V2 → SXY0/SXY1/SXY2 + SZ1/SZ2/SZ3 ─── */
	nop2, gte_cmdw_rotate_translate_perspective_triple,

	/* ── 4. NCLIP — backface culling on SXY0/SXY1/SXY2 (p0,p1,p2) ──────── */
	/*     MUST be done BEFORE V3-RTPS overwrites SXY0 with p3.             */
	nop2, gte_cmdw_nclip,

	/* ── 5. Cull check: skip format/insert if MAC0 ≤ 0 (backface) ───────── */
	nop2,  gte_mv_from_data_r(R_T0, C2_MAC0),
	nop,                                                          /* COP2 stall */
	branch_le_zero(R_T0, atom_offset(cull, cube_g4_face_exit)),
	nop,                                                          /* BD slot    */

	/* ── 6. Format c0..c3 (color+code words) BEFORE V3-RTPS ─────────────── */
	store_word(R_0, R_PrimCursor, O_(Poly_G4, tag)),
	mac_format_g4_color(
		/* c0 magenta */ 0xFF, 0x00, 0xFF,
		/* c1 yellow  */ 0xFF, 0xFF, 0x00,
		/* c2 cyan    */ 0x00, 0xFF, 0xFF,
		/* c3 green   */ 0x00, 0xFF, 0x00),

	/* ── 7. Store p0..p2 BEFORE V3-RTPS overwrites SXY0 ─────────────────── */
	mac_gte_store_g4_p012_post_rtpt_pre_rtps(),

	/* ── 8. Load V3 = verts[face->w] into V0 ─────────────────────────────── */
	shift_lleft(R_AT, R_T3, v3s2_byteoff), add_u(R_AT, R_AT, R_VertBase),
	load_word(R_V0, R_AT, O_(V3_S2, x)),   load_word(R_V1, R_AT, O_(V3_S2, z)),
	gte_mv_to_data_r(R_V0, C2_VXY0),       gte_mv_to_data_r(R_V1, C2_VZ0),

	/* ── 9. RTPS — transforms V0 (now V3) → SXY0 (p3) + SZ3 ─────────────── */
	nop2, gte_cmdw_rotate_translate_perspective_single,
	mac_gte_store_g4_p3_post_rtps(),

	/* ── 10. AVSZ4 — average Z from SZ0/SZ1/SZ2/SZ3 ─────────────────────── */
	nop2, gte_cmdw_avg_sort_z4,
	nop2, gte_mv_from_data_r(R_T1, C2_OTZ),

	/* ── 11. Bounds check OTZ < OrderingTbl_Len ─────────────────────────── */
	add_ui(      R_AT, R_0,  OrderingTbl_Len),
	set_lt_u(    R_AT, R_T1, R_AT),
	branch_equal(R_AT, R_0,  atom_offset(bounds_chk, cube_g4_face_exit)), nop,

	/* ── 12. Insert into Ordering Table (length = 8 words for Poly_G4) ──── */
	mac_insert_ot_tag_g4(),

	/* ── 13. Advance cursors & yield (both branch targets land here) ────── */
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
	atom_region(rbind_floor_f3_face, REGION_PRIM_ARENA)
	atom_group(rbind_floor_f3_face, GROUP_RENDER_FLOOR)
	atom_cadence(rbind_floor_f3_face, CADENCE_FRAME)
	atom_annot(rbind_floor_f3_face, phase_bind
		, atom_reads()
		, atom_writes(R_PrimCursor, R_FaceCursor, R_VertBase, R_OtBase))
internal 
MipsAtom_(rbind_floor_f3_face) {
	/* Pop 4 arguments from the tape directly into the workspace registers */
	load_word(R_PrimCursor, R_TapePtr, O_(Binds_FloorTri,PrimCursor)), 
	load_word(R_FaceCursor, R_TapePtr, O_(Binds_FloorTri,FaceCursor)), 
	load_word(R_VertBase,   R_TapePtr, O_(Binds_FloorTri,VertBase)), 
	load_word(R_OtBase,     R_TapePtr, O_(Binds_FloorTri,OtBase)), 
	add_ui_self(            R_TapePtr, S_(Binds_FloorTri)),
	mac_yield()
};

	atom_region( floor_f3_face, REGION_PRIM_ARENA)
	atom_group(  floor_f3_face, GROUP_RENDER_FLOOR)
	atom_cadence(floor_f3_face, CADENCE_FRAME)
	atom_annot(  floor_f3_face, phase_work,
		atom_reads( R_PrimCursor, R_FaceCursor, R_VertBase, R_OtBase),
		atom_writes(R_PrimCursor, R_FaceCursor)) 
internal 
MipsAtom_(floor_f3_face) {
	mac_load_tri_indices(R_T0, R_T1, R_T2),
	mac_load_tri_verts(  R_T0, R_T1, R_T2),
	nop2, gte_cmdw_rotate_translate_perspective_triple,
	nop2, gte_cmdw_nclip,
 
	/* Culling (Branch forward if Backface) */
	nop2, gte_mv_from_data_r(R_T0, C2_MAC0),
	nop,
	branch_le_zero(R_T0, atom_offset(culling, floor_f3_face_exit)), nop,
	/* Format Primitive */
	// mac_format_f3_color(0x20FF, 0xFFFF),  // works
	mac_format_f3_color(0xFF, 0xFF, 0xFF),  // RGB-form (R=FF, G=FF, B=FF = white)
	mac_gte_store_f3_post_rtpt(),
	
	/* Calculate Depth */
	nop2, gte_avg_sort_z3,            
	nop2, gte_mv_from_data_r(R_T1, C2_OTZ),      
	/* Bounds Check OTZ < 2048 (Branch forward to skip insertion) */
	add_ui(      R_AT, R_0,  OrderingTbl_Len),   
	set_lt_u(    R_AT, R_T1, R_AT), 
	branch_equal(R_AT, R_0,  atom_offset(bounds_chk, floor_f3_face_exit)), nop, 
	/* Insert into Ordering Table Linked List */
	mac_insert_ot_tag_f3(),
	add_ui_self(R_PrimCursor, S_(Poly_F3)), /* Advance Prim Cursor (5 words) */
		// Note(Ed): No bounds checking, should be checked before atom runs.

/* Advance Input Cursor & Yield (Both branch targets land here) */
atom_label(floor_f3_face_exit) 
	add_ui_self(R_FaceCursor, S_(S2) * 4),  /* Advance Face Cursor (4 * S2 = 8 bytes) */
	mac_yield()
};

typedef Struct_(Binds_SyncPrimitiveArena) { U4 used; U4 cursor; };
	atom_region( sync_primitive_arena, REGION_PRIM_ARENA)
	atom_group(  sync_primitive_arena, GROUP_RENDER_FLOOR)
	atom_cadence(sync_primitive_arena, CADENCE_FRAME)
	atom_annot(  sync_primitive_arena, phase_work,
		atom_reads( R_TapePtr, R_PrimCursor),
		atom_writes(R_TapePtr)) 
internal MipsAtom_(sync_primitive_arena) {
	load_word(R_AT, R_TapePtr, O_(Binds_SyncPrimitiveArena,used)),
	load_word(R_T0, R_TapePtr, O_(Binds_SyncPrimitiveArena,cursor)),      
	add_ui_self(    R_TapePtr, S_(Binds_SyncPrimitiveArena)),
	/* Calculate byte offset and store directly back to RAM */
	sub_u(     R_T0, R_PrimCursor, R_T0), // R_T0    = R_PrimCursor - binds.cursor
	store_word(R_T0, R_AT, 0),            // R_AT[0] = R_T0
	mac_yield()
};

#pragma endregion Baked Atoms
