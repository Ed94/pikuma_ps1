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
FI_ Slice_MipsCode ac_load_tri_indices(AtomBuilder_R ab, U4 r_face_cusor, U4 r_i0, U4 r_i1, U4 r_i2)
atom_dbg_skip MipsAtomComp_Proc_(ab, {
	load_half_u(r_i0, r_face_cusor, 0 * S_(S2)),
	load_half_u(r_i1, r_face_cusor, 1 * S_(S2)),
	load_half_u(r_i2, r_face_cusor, 2 * S_(S2)),
})

FI_ Slice_MipsCode ac_gte_mv_to_cr_diag_v3s4(AtomBuilder_R ab, Reg_(V3_S4) v) MipsAtomComp_Proc_(ab, {
	gte_mv_to_ctrl_r(v.y, gte_cr_RT13),
	gte_mv_to_ctrl_r(v.z, gte_cr_RT22),
	gte_mv_to_ctrl_r(v.x, gte_cr_RT11),
})

FI_ Slice_MipsCode ac_gte_ld_ir123_v3s4(AtomBuilder_R ab, Reg_(V3_S4) v) MipsAtomComp_Proc_(ab, {
	gte_mv_to_data_r(v.x, C2_IR1),
	gte_mv_to_data_r(v.y, C2_IR2),
	gte_mv_to_data_r(v.z, C2_IR3),
})

/* ─── GTE OP cross product (a × b → a) ───
 * Sets up RT diagonal from a.xyz, IR1/2/3 from b.xyz, fires OP,
 * reads MAC1/2/3, shifts right 12 (S12.20 → S12.0 OuterProduct12), writes back to a.xyz.
 * Composes the three sub-primitives (RT-load, IR-load, OP, MAC-read, shift)
 * into one component for use by atoms that need the cross product inline.
 *
 * Output gpr (a) aliases source-A gpr; MAC read clobbers source-A's load targets,
 * but by that point the RT load is complete and source A is dead.
 * Pipeline: clobbers IR1..3, MAC1..3, RT11..33.
 *
 * The CPU→COP2 transfer chains (3 ctc2, 3 mtc2) require a 2-slot retirement gap,
 * and the MFC2→GPR chain (3 mfc2) requires a 1-slot retirement gap, before the GPR can be read.
 * The hazard nops are inlined below — same convention as ac_gte_gpf_scale — so any atom body inlining this component inherits them.
 *
 * Words: 18 (3 ctc2 + 2 nop + 3 mtc2 + 2 nop + 1 op + 3 mfc2 + 1 nop + 3 sra).
 */
FI_ Slice_MipsCode ac_gte_op_cross_v3s4(AtomBuilder_R ab, Reg_(V3_S4) a, Reg_(V3_S4) b) atom_dbg_skip MipsAtomComp_Proc_(ab, {
	mac_gte_mv_to_cr_diag_v3s4(a),  GteDelay_  /* RT diagonal: D1 = a.x, D2 = a.y, D3 = a.z */
	mac_gte_ld_ir123_v3s4(b),       GteDelay_  /* IR: second operand (b.xyz) */
	gte_cmdw_cross,                            /* OP: MAC1/2/3 = a × b (S12.20) */
	mac_gte_mv_from_mac123_v3s4(a), GteDelay_  /* Read MAC1/2/3 → a.xyz (overwrites source-A's load targets) */
	mac_shift_aright_v3s4_self(a, 12), /* Right-shift MAC by 12 (S12.20 → S12.0 OuterProduct12) */
})

/* Words: 3; Stores the 3 transformed (V2_S2 screen) vertices to the F3.
 * PIPELINE: post-RTPT (SXY0=v0.screen, SXY1=v1.screen, SXY2=v2.screen). */
FI_ Slice_MipsCode ac_gte_store_f3(AtomBuilder_R ab, U4 r_primitive_cursor) atom_dbg_skip MipsAtomComp_Proc_(ab, {
	gte_sw(C2_SXY0, r_primitive_cursor, O_(Poly_F3,p0)),
	gte_sw(C2_SXY1, r_primitive_cursor, O_(Poly_F3,p1)),
	gte_sw(C2_SXY2, r_primitive_cursor, O_(Poly_F3,p2)),
})

/* Words: 18; Translates indices to vertex addresses and pushes them to GTE  */
I_ Slice_MipsCode ac_gte_load_tri_verts(AtomBuilder_R ab, U4 r_vert_base, U4 r_v0, U4 r_v1, U4 r_v2) atom_dbg_skip MipsAtomComp_Proc_(ab, {
	shift_lleft(R_AT, r_v0, v3s2_byteoff), add_u_self(R_AT, r_vert_base), load_word(R_V0, R_AT, O_(V3_S2,x)), load_word(R_V1, R_AT, O_(V3_S2,z)), LdSlot_ gte_mv_to_data_r(R_V0, C2_VXY0), gte_mv_to_data_r(R_V1, C2_VZ0),
	shift_lleft(R_AT, r_v1, v3s2_byteoff), add_u_self(R_AT, r_vert_base), load_word(R_V0, R_AT, O_(V3_S2,x)), load_word(R_V1, R_AT, O_(V3_S2,z)), LdSlot_ gte_mv_to_data_r(R_V0, C2_VXY1), gte_mv_to_data_r(R_V1, C2_VZ1),
	shift_lleft(R_AT, r_v2, v3s2_byteoff), add_u_self(R_AT, r_vert_base), load_word(R_V0, R_AT, O_(V3_S2,x)), load_word(R_V1, R_AT, O_(V3_S2,z)), LdSlot_ gte_mv_to_data_r(R_V0, C2_VXY2), gte_mv_to_data_r(R_V1, C2_VZ2),
})

/* Words: 3; Stores the 3 transformed (V2_S2 screen) vertices of the
 * G4 triangle portion to p0/p1/p2.
 * PIPELINE: post-RTPT, pre-RTPS (SXY0=v0.screen, SXY1=v1.screen, SXY2=v2.screen).
 * MUST be called BEFORE V3-RTPS, otherwise SXY0/1/2 get overwritten with v3
 * (RTPS writes only to SXY2, but to keep the three registers aligned with v0/v1/v2 you must store before RTPS). */
FI_ Slice_MipsCode ac_gte_store_g4_p012(AtomBuilder_R ab, Reg r_primitive_cursor) atom_dbg_skip MipsAtomComp_Proc_(ab, {
	gte_sw(C2_SXY0, r_primitive_cursor, O_(Poly_G4,p0)),
	gte_sw(C2_SXY1, r_primitive_cursor, O_(Poly_G4,p1)),
	gte_sw(C2_SXY2, r_primitive_cursor, O_(Poly_G4,p2)),
})

/* Words: 1; Stores the V3 screen coord to the G4's p3 slot.
 * PIPELINE: post-RTPS (SXY2 holds v3.screen because RTPS writes its single-vertex result to SXY2;
 * SXY0 still holds v0.screen from the earlier RTPT.
 */
FI_ Slice_MipsCode ac_gte_store_g4_p3(AtomBuilder_R ab, U4 r_primitive_cursor) atom_dbg_skip MipsAtomComp_Proc_(ab, { gte_sw(C2_SXY2, r_primitive_cursor, O_(Poly_G4,p3)) })

/* ─── STAGE 1 of normalize: SQR + mfc2 MAC1/2/3 ───
 * Emits squared magnitude per component (in MAC1/2/3) into caller-provided scratch regs. */
FI_ Slice_MipsCode ac_gte_sqr_v3(AtomBuilder_R ab, U4 r_sx, U4 r_sy, U4 r_sz, U4 r_sq_x, U4 r_sq_y, U4 r_sq_z) atom_dbg_skip MipsAtomComp_Proc_(ab, {
	mac_gte_sqr_v3s4(r_sx, r_sy, r_sz, nop),
	gte_mv_from_data_r(r_sq_x, C2_MAC1),
	gte_mv_from_data_r(r_sq_y, C2_MAC2),
	gte_mv_from_data_r(r_sq_z, C2_MAC3),
})

/* ─── SQR FIRE — mtc2 3 GPRs into IR1/IR2/IR3, then fire SQR. ─── */
FI_ Slice_MipsCode ac_gte_sqr_v3s4(AtomBuilder_R ab, Reg r_sx, Reg r_sy, Reg r_sz, MipsCode delay_slot)
atom_dbg_skip MipsAtomComp_Proc_(ab, {
	gte_mv_to_data_r(r_sx, C2_IR1),
	gte_mv_to_data_r(r_sy, C2_IR2),
	gte_mv_to_data_r(r_sz, C2_IR3),
	delay_slot, gte_cmdw_sqr,
})

/* ─── STAGE 4 of normalize: mtc2 IR0..3 + GPF + mfc2 MAC + srav finalize ───
 * Reusable standalone — given an IR0 = 1/|v| estimate (typically from a sqrtbl lookup) and a shift count 
 * (typically (31 - LZCR)/2), multiplies IR0*IR[i] via GPF and shifts right to produce the normalized output.
 * Used standalone for "scale vector by scalar".
 * Words: 11.  Clobbers: IR0..3, MAC1..3.  Uses gte_cmdw_gpf (sf=0, lm=0). */
FI_ Slice_MipsCode ac_gte_gpf_scale(AtomBuilder_R ab, 
	U4 r_sx, U4 r_sy, U4 r_sz, 
	U4 r_recip_est, U4 r_shift, 
	U4 r_dx, U4 r_dy, U4 r_dz)
atom_dbg_skip MipsAtomComp_Proc_(ab, {
	gte_mv_to_data_r(r_recip_est, C2_IR0),
	gte_mv_to_data_r(r_sx,        C2_IR1),
	gte_mv_to_data_r(r_sy,        C2_IR2),
	gte_mv_to_data_r(r_sz,        C2_IR3),
	GteDelay_ nop2, /* retire IR0..IR3 → GPF input pre-fill (matches libgte 0x80016134..0x80016138) */
	gte_cmdw_gpf,
	gte_mv_from_data_r(r_dx, C2_MAC1),
	gte_mv_from_data_r(r_dy, C2_MAC2),
	gte_mv_from_data_r(r_dz, C2_MAC3),
	shift_aright_var(r_dx, r_dx, r_shift),
	shift_aright_var(r_dy, r_dy, r_shift),
	shift_aright_var(r_dz, r_dz, r_shift),
})

/* ─── TRANS MATRIX (libgte TransMatrix port) ───
 * Atom component — auto-generates mac_trans_matrix Mac composer macro.
 * m->t = v (struct copy; libgte's TransMatrix at 0x8001a540 is just 3 store_words, no GTE, no add).
 * Uses 1 GPR (r_t1 = off value) per axis; per-axis load-delay-slot pattern.
 * Words: 9.  Clobbers: r_t1. */
FI_ Slice_MipsCode ac_trans_mt3s3s4(AtomBuilder_R ab
	,	U4 r_mtx, U4 r_off
	,	U4 r_t0, U4 r_t1, U4 r_t2
) MipsAtomComp_Proc_(ab, {
	load_word( r_t0, r_off, O_(V3_S4,x)),
	load_word( r_t1, r_off, O_(V3_S4,y)),
	load_word( r_t2, r_off, O_(V3_S4,z)),
	store_word(r_t0, r_mtx, O_(MT3_S2S4,t[0])),
	store_word(r_t1, r_mtx, O_(MT3_S2S4,t[1])),
	store_word(r_t2, r_mtx, O_(MT3_S2S4,t[2])),
})

/* ─── LZCR ROUND EVEN + HALF-SHIFT ───
 * Takes the raw LZCR leading-zero/ones count (from mfc2 C2_LZCR, range 1..32 per PSX-SPX cop2r31) and the |v|² sum (in r_mag_sq from the MAC1+MAC2+MAC3 add).
 * Produces:
 *   r_shift        ← LZCR rounded down to even (clear bit 0)
 *   r_mag_sq_copy  ← |v|² sum (moved out of r_mag_sq before it's overwritten)
 *   r_mag_sq       ← (31 - even_LZCR) / 2 = the final srav/GPF shift amount
 *
 * Rounding to even ensures (31 - LZCR) is always odd, so the >> 1 division is consistent — no 0.5 loss.
 * The caller branches on LZCR < 24 to decide left-shift vs right-shift of r_mag_sq_copy, then saves the shift count.
 *
 * Note: C2_LZCR (cop2r31) is a fixed read-only C2 data register — the caller must read it via mfc2 from C2_LZCR;
 * there is no register choice at the hardware level. Only the GPR that holds the result is caller-determined. */
FI_ Slice_MipsCode ac_lzcr_round_even_half_shift(AtomBuilder_R ab,
	U4 r_shift,
	U4 r_mag_sq,
	U4 r_mag_sq_copy)
atom_dbg_skip MipsAtomComp_Proc_(ab, {
	and_i(r_shift, r_shift, gte_lzcr_even_mask),
	or_u(r_mag_sq_copy, r_mag_sq, 0),
	li_s(        r_mag_sq, 31),
	sub_s(       r_mag_sq, r_mag_sq, r_shift),
	shift_aright(r_mag_sq, r_mag_sq, 1),
})

FI_ Slice_MipsCode ac_gte_general_purpose_interopolation(AtomBuilder_R ab
	, Reg to_ir0,  Reg to_ir1,  Reg to_ir2, Reg to_ir3
	, Reg fr_mac1, Reg fr_mac2, Reg fr_mac3
	, MipsCode nop_slot1, MipsCode nop_slot2)
MipsAtomComp_Proc_(ab, {
	gte_mv_to_data_r(to_ir0, C2_IR0),
	gte_mv_to_data_r(to_ir1, C2_IR1), /* IR1 = src.x (preserved in r_tmp — r_mac2_scratch was clobbered to MAC2 in stage 1.5) */
	gte_mv_to_data_r(to_ir2, C2_IR2),
	gte_mv_to_data_r(to_ir3, C2_IR3), /* IR3 = src.z (reloaded) */
	GteDelay_ nop_slot1,
	GteDelay_ nop_slot2,
	gte_cmdw_gpf,
	gte_mv_from_data_r(fr_mac1, C2_MAC1),
	gte_mv_from_data_r(fr_mac2, C2_MAC2),
	gte_mv_from_data_r(fr_mac3, C2_MAC3),
})

FI_ Slice_MipsCode ac_gte_mv_from_data_r_mac123(AtomBuilder_R ab
	, Reg fr_mac1, Reg fr_mac2, Reg fr_mac3)
MipsAtomComp_Proc_(ab, {
	gte_mv_from_data_r(fr_mac1, C2_MAC1),
	gte_mv_from_data_r(fr_mac2, C2_MAC2),
	gte_mv_from_data_r(fr_mac3, C2_MAC3),
})


FI_ Slice_MipsCode ac_gte_mv_from_mac123_v3s4(AtomBuilder_R ab, Reg_(V3_S4) v) MipsAtomComp_ProcMap_(ab, mac_gte_mv_from_data_r_mac123(v.x, v.y, v.z))

#pragma endregion MACs (Mips Atom Components)

#pragma region Atom Procs

/* ─── Local copy of PSYQ's sqrtbl (1/sqrt lookup table for VectorNormal). ───
 * Source: PSYQ 4.7 libgte sqrtbl at 0x800185B4 in hello_camera.elf.
 *   objdump -s --start-address=0x800185B4 --stop-address=0x800185F4 hello_camera.elf → 192 entries × 16-bit signed, in 1.12 fixed-point (max value 0x1000 = 1.0).
 *
 * Data is identical to the libgte original (byte-for-byte verified).
 * 
 * ─── Per-entry semantics (decoded from libgte msc02 VectorNormal) ───
 * Each entry is `1/sqrt(x)` in 1.12 fixed point (value / 4096).
 * The 192 entries span 4 octaves of the input magnitude, with 48 entries per octave:
 *   Octave 0 (entries  0- 47): mantissa in [0x8000,  0x10000)  output ~[1.000, 0.707]
 *   Octave 1 (entries 48- 95): mantissa in [0x10000, 0x20000)  output ~[0.707, 0.500]
 *   Octave 2 (entries 96-143): mantissa in [0x20000, 0x40000)  output ~[0.500, 0.354]
 *   Octave 3 (entries144-191): mantissa in [0x40000, 0x80000)  output ~[0.354, 0.251]
 * Within each octave, 8 sub-entries interpolate over the 8 fractional bits of the mantissa
 * (the byte `(0x80 | (i mod 8))` for the lower-byte of the aligned value).
 * Sampling the first value of each octave:
 *   [0]   0x1000 = 1.0000                 ; 1 / sqrt(1.0000)
 *   [48]  0x0e4f = 0.8940                 ; 1 / sqrt(1.2500)
 *   [96]  0x0d10 = 0.8164                 ; 1 / sqrt(1.5000)
 *   [144] 0x0c0a = 0.7520                 ; 1 / sqrt(1.7500)
 * And representative sub-entries within octave 0 (mantissa in [0x8000, 0x8100)):
 *   [0]   0x1000 = 1.0000                 ; 1 / sqrt(0x8000)
 *   [1]   0x0fe0 = 0.9922                 ; 1 / sqrt(0x8100)
 *   [2]   0x0fc1 = 0.9846                 ; 1 / sqrt(0x8200)
 *   [3]   0x0fa3 = 0.9773                 ; 1 / sqrt(0x8300)
 *   [4]   0x0f85 = 0.9700                 ; 1 / sqrt(0x8400)
 *   [5]   0x0f68 = 0.9629                 ; 1 / sqrt(0x8500)
 *   [6]   0x0f4c = 0.9561                 ; 1 / sqrt(0x8600)
 *   [7]   0x0f30 = 0.9492                 ; 1 / sqrt(0x8700)
 *
 * The algorithm's `addi -64 / sll 1 / lh` selects the entry at `(aligned - 64) * 2` for the case where `aligned` has its top bit at bit 24.
 * After the sllv/srav pair, `aligned` always lands in `[0x80, 0x100)` 
 * (with top bit at bit 24 → after `sub $aligned - 64`, the index sits in `[0x40, 0x80) * 2 = [0x80, 0x100)` bytes = entries [64, 128) within the sqrtbl).
 * The earlier 64 entries (octave 0) are reached when the magnitude after shifting puts the top bit below bit 24 (the `sllv` branch),
 * and the load upper_halves of the table bracket the input range.
 * The later 64 entries (octaves 2-3) are the `srav` branch when the magnitude's top bit is well above bit 24.
 *
 * Reproduced verbatim from libgte (verified against libpsn00b/psxgte/vector.s:100-123 — 24 rows × 8 halfwords, last entry 0x0804).
 * */
internal S2 const gte_normalize_sqr_tbl[192] align_(2) = {
	0x1000, 0x0fe0, 0x0fc1, 0x0fa3, 0x0f85, 0x0f68, 0x0f4c, 0x0f30,
	0x0f15, 0x0efb, 0x0ee1, 0x0ec7, 0x0eae, 0x0e96, 0x0e7e, 0x0e66,
	0x0e4f, 0x0e38, 0x0e22, 0x0e0c, 0x0df7, 0x0de2, 0x0dcd, 0x0db9,
	0x0da5, 0x0d91, 0x0d7e, 0x0d6b, 0x0d58, 0x0d45, 0x0d33, 0x0d21,
	0x0d10, 0x0cff, 0x0cee, 0x0cdd, 0x0ccc, 0x0cbc, 0x0cac, 0x0c9c,
	0x0c8d, 0x0c7d, 0x0c6e, 0x0c5f, 0x0c51, 0x0c42, 0x0c34, 0x0c26,
	0x0c18, 0x0c0a, 0x0bfd, 0x0bef, 0x0be2, 0x0bd5, 0x0bc8, 0x0bbb,
	0x0baf, 0x0ba2, 0x0b96, 0x0b8a, 0x0b7e, 0x0b72, 0x0b67, 0x0b5b,
	0x0b50, 0x0b45, 0x0b39, 0x0b2e, 0x0b24, 0x0b19, 0x0b0e, 0x0b04,
	0x0af9, 0x0aef, 0x0ae5, 0x0adb, 0x0ad1, 0x0ac7, 0x0abd, 0x0ab4,
	0x0aaa, 0x0aa1, 0x0a97, 0x0a8e, 0x0a85, 0x0a7c, 0x0a73, 0x0a6a,
	0x0a61, 0x0a59, 0x0a50, 0x0a47, 0x0a3f, 0x0a37, 0x0a2e, 0x0a26,
	0x0a1e, 0x0a16, 0x0a0e, 0x0a06, 0x09fe, 0x09f6, 0x09ef, 0x09e7,
	0x09e0, 0x09d8, 0x09d1, 0x09c9, 0x09c2, 0x09bb, 0x09b4, 0x09ad,
	0x09a5, 0x099e, 0x0998, 0x0991, 0x098a, 0x0983, 0x097c, 0x0976,
	0x096f, 0x0969, 0x0962, 0x095c, 0x0955, 0x094f, 0x0949, 0x0943,
	0x093c, 0x0936, 0x0930, 0x092a, 0x0924, 0x091e, 0x0918, 0x0912,
	0x090d, 0x0907, 0x0901, 0x08fb, 0x08f6, 0x08f0, 0x08eb, 0x08e5,
	0x08e0, 0x08da, 0x08d5, 0x08cf, 0x08ca, 0x08c5, 0x08bf, 0x08ba,
	0x08b5, 0x08b0, 0x08ab, 0x08a6, 0x08a1, 0x089c, 0x0897, 0x0892,
	0x088d, 0x0888, 0x0883, 0x087e, 0x087a, 0x0875, 0x0870, 0x086b,
	0x0867, 0x0862, 0x085e, 0x0859, 0x0855, 0x0850, 0x084c, 0x0847,
	0x0843, 0x083e, 0x083a, 0x0836, 0x0831, 0x082d, 0x0829, 0x0824,
	0x0820, 0x081c, 0x0818, 0x0814, 0x0810, 0x080c, 0x0808, 0x0804,
};

typedef Struct_(Binds_NormalizeV3S4) {
	U2 src_offset;    /* offset of src V3_S4 within the BIOS scratchpad */
	U2 dst_offset;    /* offset of dst V3_S4 within the BIOS scratchpad */
};
typedef Struct_(RegUse_build_normalize_v3s4) {
	Reg src_ptr;
	Reg dst_ptr;
	Reg src_x;
	Reg src_z;
	Reg recip_est;
	Reg norm;
	Reg shift;
	union {
		Reg v_sqr_aligned, dst_offset;
	} t3;
	union { Reg mac2; } t4;
	union { Reg btarget, shift_count, sqrtbl_index, src_offset; } t5;
};
/* ─── Full normalize (all 4 stages inline) ───
 * Generic 4-stage GTE normalize (SQR → sum+LZCR → align+sqrtbl → GPF+srav). */
internal MipsAtom* build_normalize_v3s4(AtomArena_R aa, RegUse_build_normalize_v3s4 r)
MipsAtom_Proc_(aa, {
	load_half(r.t5.src_offset, R_TapePtr, O_(Binds_NormalizeV3S4, src_offset)),
	load_half(r.t3.dst_offset, R_TapePtr, O_(Binds_NormalizeV3S4, dst_offset)),
	LdSlot_ add_u(r.src_ptr, R_ScratchBase, r.t5.src_offset),
	LdSlot_ add_u(r.dst_ptr, R_ScratchBase, r.t3.dst_offset),
	LdSlot_ add_ui_self(R_TapePtr, S_(Binds_NormalizeV3S4)),

	/* Load src.x/y/z from r_src_ptr (caller-determined address) into r_src_x / r_recip_est / r_src_z.
	 * r_src_x holds src.x throughout stages 1-2; r_recip_est (which is src.y during this phase) is reused as MAC2 in stage 4. */
	mac_load_word_v3(r.src_x, r.recip_est, r.src_z, r.src_ptr, 0),

	/* Stage 1: mtc2 src → IR1/2/3, SQR fires. */
	LdSlot_ mac_gte_sqr_v3s4(r.src_x, r.recip_est, r.src_z, LdSlot_ nop),

	/* Stage 2: mfc2 MAC1/2/3, sum, mtc2 LZCS. */
	mac_gte_mv_from_data_r_mac123(r.t3.v_sqr_aligned, r.t4.mac2, r.norm), LdSlot_ nop,
	add_u_self(        r.norm, r.t3.v_sqr_aligned),
	add_u_self(        r.norm, r.t4.mac2),
	gte_mv_to_data_r(  r.norm,  C2_LZCS), GteDelay_ nop2,
	gte_mv_from_data_r(r.shift, C2_LZCR), GteDelay_ nop,

	/* Stage 3: round LZCR to even, compute half-shift, align |v|² to bit 24.
	 * r_norm holds |v|² sum; r_shift holds the LZCR count from mfc2.
	 * After the component: r_shift = even(LZCR), r_norm = half-shift, r_t3.v_sqr_aligned = |v|². */
	mac_lzcr_round_even_half_shift(r.shift, r.norm, r.t3.v_sqr_aligned),
	add_si(        r.t5.btarget, r.shift, -24),
	branch_lt_zero(r.t5.btarget, atom_offset(aligned_done, srav_path)), BdSlot_ nop, /* bltz → srav_path (LZCR <  24 path) */
		jump_rel(atom_offset(srav_path, aligned_done)),                                /* b → aligned_done (LZCR >= 24 path) */
		BdSlot_ shift_lleft_var(r.t3.v_sqr_aligned, r.t3.v_sqr_aligned, r.t5.btarget),
		atom_label(srav_path)
			li_s( r.t5.shift_count, 24),
			sub_s(r.t5.shift_count, r.t5.shift_count, r.shift),
			shift_aright_var(r.t3.v_sqr_aligned, r.t3.v_sqr_aligned, r.t5.shift_count),
	atom_label(aligned_done)
		// Save the shift count to r_shift before the next 5 instructions overwrite r_norm (the sqrtbl lookup loads 1/|v| into r_norm, which becomes IR0 in stage 4).
		or_u(r.shift, r.norm, 0), /* r_shift ← shift count (preserved through stage 4) */
		add_si(     r.t3.v_sqr_aligned, r.t3.v_sqr_aligned, -64), /* r_t3.v_sqr_aligned holds |v|² aligned (top bit at bit 7). */
		shift_lleft(r.t3.v_sqr_aligned, r.t3.v_sqr_aligned, 1),
		mac_load_word_imm(r.t5.sqrtbl_index, & gte_normalize_sqr_tbl), add_u_self(r.t5.sqrtbl_index, r.t3.v_sqr_aligned),
		load_half(r.norm, r.t5.sqrtbl_index, 0), /* r_norm = sqrtbl[aligned-64] = 1/|v| (IR0 in stage 4) */
		LdSlot_ nop,

	/* r.src_z holds src.z from the initial load (r.src_z is a dedicated slot,
	 * never clobbered between the load at body start and the stage-4 GPF use below).
	 * Stage 4: GPF + srav finalize (r_shift = shift count, r_norm = 1/|v|). */
	mac_gte_general_purpose_interopolation(
		r.norm,
		r.src_x,  /* IR1 = src.x (preserved in r_tmp — r_mac2_scratch was clobbered to MAC2 in stage 1.5) */
		r.recip_est,
		r.src_z,  /* IR3 = src.z (reloaded) */
		r.t4.mac2, r.recip_est, r.src_z,
		GteDelay_ nop,
		GteDelay_ nop
	),
	/* sra by r_shift = (31-LZCR)/2 (saved before sqrtbl lookup) */
	mac_shift_aright_var_v3_self(r.t4.mac2, r.recip_est, r.src_z, r.shift),
	/* Store result.x/y/z to r_dst_ptr (caller-determined dst address). */
	mac_store_word_v3(r.t4.mac2, r.recip_est, r.src_z, r.dst_ptr, 0),

	mac_yield()
})

/* ─── GTE OP cross product (a × b → out) ───
 * Generalized V3_S4 cross product via GTE OP (OuterProduct12 libpsyx convention).
 * The >> 12 shift converts S12.20 → S12.0 OuterProduct12. */
typedef Struct_(Binds_gte_cross_v3s4) { V3_S4* src_a; V3_S4* src_b; V3_S4* out; };
typedef Struct_(RegUse_gte_cross_v3s4) {
	Reg_(V3_S4) a;
	Reg_(V3_S4) b;
	union { Reg out, t0; } x;
	union { Reg src_a, t1, rt11; } y;
	union { Reg src_b, t2, rt22; } z;
};
internal MipsAtom* gte_cross_v3s4(AtomArena_R aa, RegUse_gte_cross_v3s4 r)
atom_info(atom_bind(Binds_gte_cross_v3s4)) MipsAtom_Proc_(aa, {
	load_word(r.y.src_a,  R_TapePtr, O_(Binds_gte_cross_v3s4,src_a)),
	load_word(r.z.src_b,  R_TapePtr, O_(Binds_gte_cross_v3s4,src_b)),
	load_word(r.x.out,    R_TapePtr, O_(Binds_gte_cross_v3s4,out)),
	LdSlot_ add_ui_self(  R_TapePtr, S_(Binds_gte_cross_v3s4)),

	mac_load_v3s4(r.a, r.y.src_a, 0), LdSlot_
	mac_load_v3s4(r.b, r.z.src_b, 0), LdSlot_
	mac_gte_op_cross_v3s4(r.a, r.b), /* RT diagonal + IR + OP + MAC read + shift */
	mac_store_v3s4(r.a, r.x.out, 0),

	mac_yield()
})
#pragma endregion Atom Procs

#pragma region Baked Atoms

typedef Struct_(Binds_SetGteMT3S2S4) {
	MT3_S2S4* transform;
};
internal MipsAtom_(set_gte_mt3s2s4) atom_info(
		atom_bind(Binds_SetGteMT3S2S4)
	,	atom_reads(R_TapePtr)
){
	/* Pop matrix address from tape into R_T3 ($11) */
	load_word(R_T3, R_TapePtr, O_(Binds_SetGteMT3S2S4,transform)),
	add_ui_self(    R_TapePtr, S_(Binds_SetGteMT3S2S4)),
	/* Load 3x3 Rotation + 3x1 Translation from R_T3 into GTE CONTROL Regs (ctc2) */
	load_word(R_T0, R_T3, 0), 
	load_word(R_T1, R_T3, 4), 
	gte_mv_to_ctrl_r(R_T0, gte_cr_RT11),
	gte_mv_to_ctrl_r(R_T1, gte_cr_RT12),
	load_word(R_T0, R_T3,  8),
	load_word(R_T1, R_T3, 12),
	load_word(R_T2, R_T3, 16),
	gte_mv_to_ctrl_r(R_T0, gte_cr_RT13),
	gte_mv_to_ctrl_r(R_T1, gte_cr_RT21),
	gte_mv_to_ctrl_r(R_T2, gte_cr_RT22),
	load_word(R_T0, R_T3, 20),
	load_word(R_T1, R_T3, 24),
	load_word(R_T2, R_T3, 28),
	gte_mv_to_ctrl_r(R_T0, gte_cr_TRX),
	gte_mv_to_ctrl_r(R_T1, gte_cr_TRY),
	gte_mv_to_ctrl_r(R_T2, gte_cr_TRZ),
	mac_yield()
};

#pragma endregion Baked Atoms
