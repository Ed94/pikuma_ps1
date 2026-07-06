#ifdef INTELLISENSE_DIRECTIVES
#	include "duffle/lottes_tape.h"
#	include "hello_gte.h"
#	include "tape_atom.metadata.h"
#	include "gen/hello_gte_tape.offsets.h"
#endif

#pragma region MACs (Mips Atom components)

/* Words: 3; High: 0x20/B, Low: G/R */
#define mac_format_f3_color(color_hi, color_lo) \
	  load_ui(R_AT, color_hi), or_i(R_AT, R_AT, color_lo) \
	, store_word(R_AT, R_PrimCur, O_(Poly_F3,color))   \

/* Words: 3 */
#define mac_gte_store_f3() \
	  gte_sw(C2_SXY0, R_PrimCur, O_(Poly_F3,p0)) \
	, gte_sw(C2_SXY1, R_PrimCur, O_(Poly_F3,p1)) \
	, gte_sw(C2_SXY2, R_PrimCur, O_(Poly_F3,p2))

#pragma endregion MACs

#pragma region Baked Atoms

internal MipsAtom_(floor_tri) {
	// T0-T2 allocated
	// mac_load_tri_indices(R_T0, R_T1, R_T2),
		  load_half_u(R_T0, R_FaceCur, 0 * S_(S2))
		, load_half_u(R_T1, R_FaceCur, 1 * S_(S2))
		, load_half_u(R_T2, R_FaceCur, 2 * S_(S2))
	,
	// mac_load_tri_verts(  R_T0, R_T1, R_T2),
			shift_ll(R_AT, R_T0, 3), add_u(R_AT, R_AT, R_VertBase), load_word(R_V0, R_AT, 0), load_word(R_V1, R_AT, 4), gte_mt(R_V0, C2_VXY0), gte_mt(R_V1, C2_VZ0)
		, shift_ll(R_AT, R_T1, 3), add_u(R_AT, R_AT, R_VertBase), load_word(R_V0, R_AT, 0), load_word(R_V1, R_AT, 4), gte_mt(R_V0, C2_VXY1), gte_mt(R_V1, C2_VZ1)
		, shift_ll(R_AT, R_T2, 3), add_u(R_AT, R_AT, R_VertBase), load_word(R_V0, R_AT, 0), load_word(R_V1, R_AT, 4), gte_mt(R_V0, C2_VXY2), gte_mt(R_V1, C2_VZ2)
	,

	/* 3. Execute Math */
	nop, nop, gte_cmdw_rotate_translate_perspective_triple,
	nop, nop, gte_cmdw_nclip,
	nop, nop, 

	/* 4. Culling (Branch forward if Backface) */
	gte_mf(R_T0, C2_MAC0),
	nop, branch_le_zero(R_T0, atom_offset(culling, floor_tri_exit)), 
	nop,                      
	
	/* 5. Format Primitive */
	mac_format_f3_color(0x20FF, 0xFFFF), 
	mac_gte_store_f3(),
	
	/* 6. Calculate Depth */
	nop, nop, gte_avg_sort_z3,            
	nop, nop, gte_mf(R_T1, C2_OTZ),      
	
	/* 7. Bounds Check OTZ < 2048 (Branch forward to skip insertion) */
	add_ui(      R_AT, R_0,  OrderingTbl_Len),   
	slt_u(       R_AT, R_T1, R_AT), 
	branch_equal(R_AT, R_0,  atom_offset(bounds_chk, floor_tri_exit)),   
	nop, 
	
	/* 8. Insert into Ordering Table Linked List */
	mac_insert_ot_tag(R_T1, 0x0400),
	add_ui(R_PrimCur, R_PrimCur, S_(Poly_F3)), /* Advance Prim Cursor (5 words) */

	/* 9. Advance Input Cursor & Yield (Both branch targets land here) */
atom_label(floor_tri_exit)
	add_ui(R_FaceCur, R_FaceCur, S_(S2) * 4),  /* Advance Face Cursor (4 * S2 = 8 bytes) */
	mac_yield()
};

#pragma endregion Baked Atoms
