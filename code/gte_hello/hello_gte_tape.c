#ifdef INTELLISENSE_DIRECTIVES
#	include "duffle/lottes_tape.h"
#	include "duffle/atom_dsl.h"
#	include "hello_gte.h"
#	include "tape_atom.metadata.h"
#	include "gen/hello_gte_tape.offsets.h"
#endif

#pragma region MACs (Mips Atom components)
/* The macros mac_format_f3_color and mac_gte_store_f3 moved to
 * lottes_tape.h during the Phase 3 gp.h overhaul. Both are now RGB-form
 * (mac_format_f3_color takes _r, _g, _b byte values rather than raw
 * 16-bit half-words). */

enum fack {
	ah = gp0_cmd_poly_f3 << 8 | 0xFF,
};
void fk() {
	 (void*)ah;
}

#pragma endregion MACs

#pragma region Baked Atoms

typedef Struct_(Binds_CubeTri) {
	U4 PrimCursor;
	U4 FaceCursor;
	U4 VertBase;
	U4 OtBase;
};
internal MipsAtom_(rbind_cube_tri) {
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
 *  cube_tri — Draw one cube face (Gouraud-shaded quad) via the GTE tape pipeline
 * ============================================================================
 *
 *  Reads 4 indices from R_FaceCur (V4_S2 = 8 bytes), loads 4 vertices into
 *  the GTE, runs the PsyQ RotAverageNclip4 sequence, and renders a Poly_G4.
 */
	atom_region  (cube_tri, REGION_PRIM_ARENA)
	atom_group   (cube_tri, GROUP_RENDER_PRIMS)
	atom_cadence (cube_tri, CADENCE_FRAME)
	atom_annot(cube_tri, phase_work,
		tape_regs(R_PrimCursor, R_FaceCursor, R_VertBase, R_OtBase),
		tape_regs(R_PrimCursor, R_FaceCursor))
internal 
MipsAtom_(cube_tri) {
	/* ── 1. Load 4 face indices from R_FaceCur ──────────────────────────── */
	load_half_u(R_T0, R_FaceCursor, 0),  /* T0 = face->x (vertex 0 index) */
	load_half_u(R_T1, R_FaceCursor, 2),  /* T1 = face->y (vertex 1 index) */
	load_half_u(R_T2, R_FaceCursor, 4),  /* T2 = face->z (vertex 2 index) */
	load_half_u(R_T3, R_FaceCursor, 6),  /* T3 = face->w (vertex 3 index) */

	/* ── 2. Load V0, V1, V2 into GTE ────────────────────────────────────── */
	/* V0 = verts[face->x] */
	shift_lleft(R_AT, R_T0, 3), add_u(R_AT, R_AT, R_VertBase),
	load_word(R_V0, R_AT, 0), load_word(R_V1, R_AT, 4),
	gte_mv_to_data_r(R_V0, C2_VXY0), gte_mv_to_data_r(R_V1, C2_VZ0),

	/* V1 = verts[face->y] */
	shift_lleft(R_AT, R_T1, 3), add_u(R_AT, R_AT, R_VertBase),
	load_word(R_V0, R_AT, 0), load_word(R_V1, R_AT, 4),
	gte_mv_to_data_r(R_V0, C2_VXY1), gte_mv_to_data_r(R_V1, C2_VZ1),

	/* V2 = verts[face->z] */
	shift_lleft(R_AT, R_T2, 3), add_u(R_AT, R_AT, R_VertBase),
	load_word(R_V0, R_AT, 0), load_word(R_V1, R_AT, 4),
	gte_mv_to_data_r(R_V0, C2_VXY2), gte_mv_to_data_r(R_V1, C2_VZ2),

	/* ── 3. RTPT — transforms V0/V1/V2 → SXY0/SXY1/SXY2 + SZ1/SZ2/SZ3 ─── */
	nop, nop, gte_cmdw_rtpt,

	/* ── 4. NCLIP — backface culling on SXY0/SXY1/SXY2 (p0,p1,p2) ──────── */
	/*     MUST be done BEFORE RTPS overwrites SXY0 with p3!                */
	nop, nop, gte_cmdw_nclip,
	nop, nop,

	/* ── 5. Cull check: skip format/insert if MAC0 ≤ 0 (backface) ───────── */
	gte_mv_from_data_r(R_T0, C2_MAC0),
	nop,
	branch_le_zero(R_T0, 49),  /* Skip 49 if MAC0 ≤ 0 (backface) → cull */
	nop,                        /* BD slot */

	/* ── 6. Store p0,p1,p2 to primitive buffer (BEFORE RTPS overwrites) ─── */
	store_word(R_0, R_PrimCursor, 0),

	/* Word 1: c0 (BGR) + code = 0x38FF00FF (magenta, opcode 0x38) */
	load_upper_i(R_AT, 0x38FF), or_i(R_AT, R_AT, 0x00FF),
	store_word(R_AT, R_PrimCursor, 4),

	/* Word 2: p0 = SXY0 (stored BEFORE RTPS overwrites it) */
	gte_sw(C2_SXY0, R_PrimCursor, 8),

	/* Word 3: c1 (BGR) + pad = 0x0000FFFF (yellow) */
	load_upper_i(R_AT, 0x0000), or_i(R_AT, R_AT, 0xFFFF),
	store_word(R_AT, R_PrimCursor, 12),

	/* Word 4: p1 = SXY1 */
	gte_sw(C2_SXY1, R_PrimCursor, 16),

	/* Word 5: c2 (BGR) + pad = 0x00FFFF00 (cyan) */
	load_upper_i(R_AT, 0x00FF), or_i(R_AT, R_AT, 0xFF00),
	store_word(R_AT, R_PrimCursor, 20),

	/* Word 6: p2 = SXY2 */
	gte_sw(C2_SXY2, R_PrimCursor, 24),

	/* Word 7: c3 (BGR) + pad = 0x0000FF00 (green) */
	load_upper_i(R_AT, 0x0000), or_i(R_AT, R_AT, 0xFF00),
	store_word(R_AT, R_PrimCursor, 28),

	/* ── 7. Load V3 = verts[face->w] into V0 ─────────────────────────────── */
	shift_lleft(R_AT, R_T3, 3), add_u(R_AT, R_AT, R_VertBase),
	load_word(R_V0, R_AT, 0), load_word(R_V1, R_AT, 4),
	gte_mv_to_data_r(R_V0, C2_VXY0), gte_mv_to_data_r(R_V1, C2_VZ0),

	/* ── 8. RTPS — transforms V0 (now V3) → SXY0 (p3) + SZ0 ─────────────── */
	nop, nop, gte_cmdw_rtps,

	/* Word 8: p3 = SXY0 (written AFTER RTPS with V3's screen coords) */
	gte_sw(C2_SXY0, R_PrimCursor, 32),

	/* ── 9. AVSZ4 — average Z from SZ0/SZ1/SZ2/SZ3 ────────────── */
	nop, nop, gte_cmdw_avsz4,
	nop, nop,
	gte_mv_from_data_r(R_T1, C2_OTZ),

	/* ── 10. Bounds check OTZ < 2048 ─────────────────────────────────────── */
	add_ui(      R_AT, R_0,  2048),
	set_lt_u(       R_AT, R_T1, R_AT),
	branch_equal(R_AT, R_0,  13),  /* Skip 13 → land at add_ui(R_FaceCur,...) */
	nop,                            /* BD slot */

	/* ── 11. Insert into Ordering Table (length = 8 for Poly_G4) ─────────── */
	mac_insert_ot_tag(R_T1, 0x0800),  /* 0x0800 = 8 << 8 = length 8 in tag */

	/* ── 12. Advance cursors & yield ─────────────────────────────────────── */
	add_ui(R_PrimCursor, R_PrimCursor, 36),  /* 9 words × 4 bytes */
	add_ui(R_FaceCursor, R_FaceCursor, 8),   /* 4 × S2 = 8 bytes */
	mac_yield()
};

typedef Struct_(Binds_FloorTri) {
	U4 PrimCursor;
	U4 FaceCursor;
	U4 VertBase;
	U4 OtBase;
};
	atom_region(rbind_floor_tri, REGION_PRIM_ARENA)
	atom_group(rbind_floor_tri, GROUP_RENDER_FLOOR)
	atom_cadence(rbind_floor_tri, CADENCE_FRAME)
	atom_annot(rbind_floor_tri, phase_bind
		, atom_reads()
		, atom_writes(R_PrimCursor, R_FaceCursor, R_VertBase, R_OtBase))
internal 
MipsAtom_(rbind_floor_tri) {
	/* Pop 4 arguments from the tape directly into the workspace registers */
	load_word(R_PrimCursor, R_TapePtr, O_(Binds_FloorTri,PrimCursor)), 
	load_word(R_FaceCursor, R_TapePtr, O_(Binds_FloorTri,FaceCursor)), 
	load_word(R_VertBase,   R_TapePtr, O_(Binds_FloorTri,VertBase)), 
	load_word(R_OtBase,     R_TapePtr, O_(Binds_FloorTri,OtBase)), 
	add_ui_self(            R_TapePtr, S_(Binds_FloorTri)),
	mac_yield()
};

	atom_region( floor_tri, REGION_PRIM_ARENA)
	atom_group(  floor_tri, GROUP_RENDER_FLOOR)
	atom_cadence(floor_tri, CADENCE_FRAME)
	atom_annot(  floor_tri, phase_work,
		atom_reads( R_PrimCursor, R_FaceCursor, R_VertBase, R_OtBase),
		atom_writes(R_PrimCursor, R_FaceCursor)) 
internal 
MipsAtom_(floor_tri) {
	mac_load_tri_indices(R_T0, R_T1, R_T2),
	mac_load_tri_verts(  R_T0, R_T1, R_T2),
	nop, nop, gte_cmdw_rotate_translate_perspective_triple,
	nop, nop, gte_cmdw_nclip,
	nop, nop, 
	/* Culling (Branch forward if Backface) */
	gte_mv_from_data_r(R_T0, C2_MAC0),
	nop, branch_le_zero(R_T0, atom_offset(culling, floor_tri_exit)), 
	nop,                      
	/* Format Primitive */
	// mac_format_f3_color(0x20FF, 0xFFFF),  // works
	mac_format_f3_color(0xFF, 0xFF, 0xFF),  // RGB-form (R=FF, G=FF, B=FF = white)
	mac_gte_store_f3(),
	
	/* Calculate Depth */
	nop, nop, gte_avg_sort_z3,            
	nop, nop, gte_mv_from_data_r(R_T1, C2_OTZ),      
	/* Bounds Check OTZ < 2048 (Branch forward to skip insertion) */
	add_ui(      R_AT, R_0,  OrderingTbl_Len),   
	set_lt_u(    R_AT, R_T1, R_AT), 
	branch_equal(R_AT, R_0,  atom_offset(bounds_chk, floor_tri_exit)),   
	nop, 
	/* Insert into Ordering Table Linked List */
	mac_insert_ot_tag(R_T1, 0x0400),
	add_ui_self(R_PrimCursor, S_(Poly_F3)), /* Advance Prim Cursor (5 words) */
		// Note(Ed): No bounds checking, should be checked before atom runs.

/* Advance Input Cursor & Yield (Both branch targets land here) */
atom_label(floor_tri_exit) 
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
