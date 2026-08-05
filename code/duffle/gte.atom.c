#ifdef INTELLISENSE_DIRECTIVES
#	include "gen/macs.h"
#	include "gen/offsets.h"
#	include "gte.h"
#	include "gp.h"
#	include "lottes_tape.h"	
#endif

ATOM_FILE_DEBUGGER_LINE_MARKER(gte_atom_c);

#pragma region MACs (Mips Atom Components)

/* Words: 3; Loads 3 S2 indices from the face array */
FI_ Slice_MipsCode ac_load_tri_indices(U4 r_face_cusor, U4 r_i0, U4 r_i1, U4 r_i2) atom_dbg_skip MipsAtomComp_Proc_(ac_load_tri_indices, {
	load_half_u(r_i0, r_face_cusor, 0 * S_(S2)),
	load_half_u(r_i1, r_face_cusor, 1 * S_(S2)),
	load_half_u(r_i2, r_face_cusor, 2 * S_(S2)),
})

/* Words: 3; Stores the 3 transformed (V2_S2 screen) vertices to the F3.
 * PIPELINE: post-RTPT (SXY0=v0.screen, SXY1=v1.screen, SXY2=v2.screen). */
FI_ Slice_MipsCode ac_gte_store_f3(U4 r_primitive_cursor) atom_dbg_skip MipsAtomComp_Proc_(ac_gte_store_f3, {
	gte_sw(C2_SXY0, r_primitive_cursor, O_(Poly_F3,p0)),
	gte_sw(C2_SXY1, r_primitive_cursor, O_(Poly_F3,p1)),
	gte_sw(C2_SXY2, r_primitive_cursor, O_(Poly_F3,p2)),
})

/* Words: 18; Translates indices to vertex addresses and pushes them to GTE  */
I_ Slice_MipsCode ac_gte_load_tri_verts(U4 r_vert_base, U4 r_v0, U4 r_v1, U4 r_v2) atom_dbg_skip MipsAtomComp_Proc_(ac_gte_load_tri_verts, {
	shift_lleft(R_AT, r_v0, v3s2_byteoff), add_u_self(R_AT, r_vert_base), load_word(R_V0, R_AT, O_(V3_S2,x)), load_word(R_V1, R_AT, O_(V3_S2,z)), gte_mv_to_data_r(R_V0, C2_VXY0), gte_mv_to_data_r(R_V1, C2_VZ0),
	shift_lleft(R_AT, r_v1, v3s2_byteoff), add_u_self(R_AT, r_vert_base), load_word(R_V0, R_AT, O_(V3_S2,x)), load_word(R_V1, R_AT, O_(V3_S2,z)), gte_mv_to_data_r(R_V0, C2_VXY1), gte_mv_to_data_r(R_V1, C2_VZ1),
	shift_lleft(R_AT, r_v2, v3s2_byteoff), add_u_self(R_AT, r_vert_base), load_word(R_V0, R_AT, O_(V3_S2,x)), load_word(R_V1, R_AT, O_(V3_S2,z)), gte_mv_to_data_r(R_V0, C2_VXY2), gte_mv_to_data_r(R_V1, C2_VZ2),
})

/* Words: 3; Stores the 3 transformed (V2_S2 screen) vertices of the
 * G4 triangle portion to p0/p1/p2.
 * PIPELINE: post-RTPT, pre-RTPS (SXY0=v0.screen, SXY1=v1.screen, SXY2=v2.screen). 
 * MUST be called BEFORE V3-RTPS, otherwise SXY0/1/2 get overwritten with v3
 * (RTPS writes only to SXY2, but to keep the three registers aligned with v0/v1/v2 you must store before RTPS). */
FI_ Slice_MipsCode ac_gte_store_g4_p012(U4 r_primitive_cursor) atom_dbg_skip MipsAtomComp_Proc_(ac_gte_store_g4_p012, {
	gte_sw(C2_SXY0, r_primitive_cursor, O_(Poly_G4,p0)),
	gte_sw(C2_SXY1, r_primitive_cursor, O_(Poly_G4,p1)),
	gte_sw(C2_SXY2, r_primitive_cursor, O_(Poly_G4,p2)),
})

/* Words: 1; Stores the V3 screen coord to the G4's p3 slot.
 * PIPELINE: post-RTPS (SXY2 holds v3.screen because RTPS writes its single-vertex result to SXY2;
 * SXY0 still holds v0.screen from the earlier RTPT.
 */
FI_ Slice_MipsCode ac_gte_store_g4_p3(U4 r_primitive_cursor) atom_dbg_skip MipsAtomComp_Proc_(ac_gte_store_g4_p3, { gte_sw(C2_SXY2, r_primitive_cursor, O_(Poly_G4,p3)) })

#pragma endregion MACs (Mips Atom Components)

#pragma region Bsked Atoms

typedef Struct_(Binds_SetGteWorld) {
	M3_S2* transform;
};
internal MipsAtom_(set_gte_world) atom_info(
		atom_bind(Binds_SetGteWorld)
	,	atom_reads(R_TapePtr)
){
	/* Pop matrix address from tape into R_T3 ($11) */
	load_word(R_T3, R_TapePtr, O_(Binds_SetGteWorld,transform)),
	add_ui_self(    R_TapePtr, S_(Binds_SetGteWorld)),
	/* Load 3x3 Rotation + 3x1 Translation from R_T3 into GTE CONTROL Regs (ctc2) */
	load_word(R_T0, R_T3, 0),  load_word(R_T1, R_T3,  4),
	gte_mv_to_ctrl_r(R_T0, gte_cr_RT11), gte_mv_to_ctrl_r(R_T1, gte_cr_RT12),
	load_word(R_T0, R_T3, 8),  load_word(R_T1, R_T3, 12), load_word(R_T2, R_T3, 16),
	gte_mv_to_ctrl_r(R_T0, gte_cr_RT13), gte_mv_to_ctrl_r(R_T1, gte_cr_RT21), gte_mv_to_ctrl_r(R_T2, gte_cr_RT22),
	load_word(R_T0, R_T3, 20), load_word(R_T1, R_T3, 24), load_word(R_T2, R_T3, 28),
	gte_mv_to_ctrl_r(R_T0, gte_cr_TRX),  gte_mv_to_ctrl_r(R_T1, gte_cr_TRY),  gte_mv_to_ctrl_r(R_T2, gte_cr_TRZ),
	mac_yield()
};

#pragma endregion Baked Atoms
