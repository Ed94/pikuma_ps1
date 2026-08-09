#ifdef INTELLISENSE_DIRECTIVES
#	include "dsl.h"
#	include "gp.h"
#	include "lottes_tape.h"
#endif

ATOM_FILE_DEBUGGER_LINE_MARKER(gp_atom_c);

#pragma region MACs (Mips Atom Components)

FI_ Slice_MipsCode ac_gcmd_push(U4 cmd, U4 reg_transfer, U4 reg_base, U2 port)
MipsAtomComp_Proc_(ac_gcmd_push, {
	load_upper_i(reg_transfer, cmd >> 16),
	or_i_self(   reg_transfer, cmd & 0xFFFF),
	store_word(  reg_transfer, reg_base, port),
})

FI_ Slice_MipsCode ac_store_rgb8(U1 rr, U1 rg, U1 rb, U4 base, U4 offset) atom_dbg_skip MipsAtomComp_Proc_(ac_store_rgb8, {
	store_byte(rr, base, offset + O_(RGB8,r)),
	store_byte(rg, base, offset + O_(RGB8,g)),
	store_byte(rb, base, offset + O_(RGB8,b)),	
})

FI_ Slice_MipsCode ac_pack_color_word(U4 r_base, U4 off, U4 cmd, U1 r, U1 g, U1 b)
atom_dbg_skip MipsAtomComp_Proc_(ac_pack_color_word, {
	load_upper_i(R_AT, (cmd) << 8  | (b)),
	or_i_self(   R_AT, ((g)  << 8) | (r)),
	store_word(  R_AT, r_base, (off)),
})

FI_ Slice_MipsCode ac_format_f3_color(U4 r_base, U1 r, U1 g, U1 b)
atom_dbg_skip MipsAtomComp_Proc_(ac_format_f3_color, { mac_pack_color_word(r_base, O_(Poly_F3,color), gp0_cmd_poly_f3, r, g, b) })

FI_ Slice_MipsCode ac_format_g4_color(U4 r_prim_cursor,
	U1 r0, U1 g0, U1 b0,
  U1 r1, U1 g1, U1 b1,
  U1 r2, U1 g2, U1 b2,
  U1 r3, U1 g3, U1 b3)
MipsAtomComp_Proc_(ac_format_g4_color, {
	mac_pack_color_word(r_prim_cursor, O_(Poly_G4,c0), gp0_cmd_poly_g4, r0,g0,b0),
	mac_pack_color_word(r_prim_cursor, O_(Poly_G4,c1), 0,               r1,g1,b1),
	mac_pack_color_word(r_prim_cursor, O_(Poly_G4,c2), 0,               r2,g2,b2),
	mac_pack_color_word(r_prim_cursor, O_(Poly_G4,c3), 0,               r3,g3,b3),
})

/* Words: 11; Correctly inserts a primitive into the Ordering Table linked list. */
I_ Slice_MipsCode ac_insert_ot_tag(U4 r_ot_base, U4 r_prim_cursor, U4 poly_size) MipsAtomComp_Proc_(ac_insert_ot_tag, {
	shift_lleft( R_T1, R_T1, S_(U4)/2),                        // T1 = otz * S_(U4) (otz arg is implicit R_T1)
	add_u_self(  R_T1, r_ot_base),                             // T1 = & OrderingTable[OTZ]
	load_word(   R_AT, R_T1,          O_(PolyTag,code)),       // AT = old_ot_head
	load_upper_i(R_V0, (poly_size/S_(U4) - S_(PolyTag)/S_(U4)) << PolyTag_len_bits),
	mask_upper(  R_AT, R_AT,          S_(PolyTag_len_bits)),   // Strip upper 8 bits (length from prev cell) → keep only low 24
	or_u(        R_AT, R_AT, R_V0),                            // Merge length
	store_word(  R_AT, r_prim_cursor, O_(PolyTag,code)),       // prim->tag = packed(prim_length, old_addr)
	shift_lleft( R_AT, r_prim_cursor, S_(PolyTag_len_bits)),   // AT = (prim_length << 24) | old_addr
	shift_lright(R_AT, R_AT,          S_(PolyTag_len_bits)),
	store_word(  R_AT, R_T1,          O_(PolyTag,code)),       // OrderingTable[OTZ] = PrimCursor
})

#pragma endregion MACs (Mips Atom Components)
