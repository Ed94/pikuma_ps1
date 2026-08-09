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

/* ─── STAGE 1 of normalize: SQR + mfc2 MAC1/2/3 ───
 * Emits squared magnitude per component (in MAC1/2/3) into caller-provided scratch regs.
 * Stage 2 of normalize consumes these directly.
 * Words: 8.  Clobbers: IR1/2/3, MAC1/2/3.  Uses gte_cmdw_sqr (sf=0, lm=1). */
FI_ Slice_MipsCode ac_gte_sqr_v3(U4 r_sx, U4 r_sy, U4 r_sz, U4 r_sq_x, U4 r_sq_y, U4 r_sq_z) atom_dbg_skip MipsAtomComp_Proc_(ac_gte_sqr_v3, {
	gte_mv_to_data_r(r_sx, C2_IR1),
	gte_mv_to_data_r(r_sy, C2_IR2),
	gte_mv_to_data_r(r_sz, C2_IR3),
	nop, gte_cmdw_sqr,
	gte_mv_from_data_r(r_sq_x, C2_MAC1),
	gte_mv_from_data_r(r_sq_y, C2_MAC2),
	gte_mv_from_data_r(r_sq_z, C2_MAC3),
})

/* ─── STAGE 4 of normalize: mtc2 IR0..3 + GPF + mfc2 MAC + srav finalize ───
 * Reusable standalone — given an IR0 = 1/|v| estimate (typically from a sqrtbl lookup) and a shift count 
 * (typically (31 - LZCR)/2), multiplies IR0*IR[i] via GPF and shifts right to produce the normalized output.
 * Used standalone for "scale vector by scalar".
 * Words: 11.  Clobbers: IR0..3, MAC1..3.  Uses gte_cmdw_gpf (sf=0, lm=0). */
FI_ Slice_MipsCode ac_gte_gpf_scale(U4 r_sx, U4 r_sy, U4 r_sz, U4 r_recip_est, U4 r_shift, U4 r_dx, U4 r_dy, U4 r_dz) atom_dbg_skip MipsAtomComp_Proc_(ac_gte_gpf_scale, {
	gte_mv_to_data_r(r_recip_est, C2_IR0),
	gte_mv_to_data_r(r_sx,        C2_IR1),
	gte_mv_to_data_r(r_sy,        C2_IR2),
	gte_mv_to_data_r(r_sz,        C2_IR3),
	nop2, /* retire IR0..IR3 → GPF input pre-fill (matches libgte 0x80016134..0x80016138) */
	gte_cmdw_gpf,
	gte_mv_from_data_r(r_dx, C2_MAC1),
	gte_mv_from_data_r(r_dy, C2_MAC2),
	gte_mv_from_data_r(r_dz, C2_MAC3),
	shift_aright_var(r_dx, r_dx, r_shift),
	shift_aright_var(r_dy, r_dy, r_shift),
	shift_aright_var(r_dz, r_dz, r_shift),
})

/* ─── Local copy of PSYQ's sqrtbl (1/sqrt lookup table for VectorNormal). ───
 * Source: PSYQ 4.7 libgte sqrtbl at 0x800185B4 in hello_camera.elf.
 *   objdump -s --start-address=0x800185B4 --stop-address=0x800185F4 hello_camera.elf
 *   → 192 entries × 16-bit signed, in 1.12 fixed-point (max value 0x1000 = 1.0).
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
 * Within each octave, 8 sub-entries interpolate over the 8 fractional bits of the
 * mantissa (the byte `(0x80 | (i mod 8))` for the lower-byte of the aligned value).
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
 * 192-entry table is reproduced verbatim from libgte (verified against libpsn00b/psxgte/vector.s:100-123 — 24 rows × 8 halfwords, last entry 0x0804). */
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

/* ─── Full normalize (all 4 stages inline) ───
 * Direct port of PSYQ libgte msc02.rel.text VectorNormal disassembly (0x800160a0..0x8001615c).
 *
 * Component variants that could apply:
 *   - `ac_gte_sqr_v3` (line ~56) covers stage 1's `mtc2 IR1/2/3 + nop + gte_cmdw_sqr`.
 *     We do NOT call it because the inlined version of stage 1 is followed immediately by stage 2's `mfc2 MAC1/2/3` chain 
 *     (the operands of `ac_gte_sqr_v3`'s r_sq_x/r_sq_y/r_sq_z would each require an explicit GPR to receive the MAC result,
 *      then a move to land in r_recip_est for the partial-sum chain).
 *     Inlining saves ~3 cycles of `or`-merge + register pressure
 *     (squared MAC3 lands DIRECTLY in r_recip_est which doubles as the partial-sum accumulator and the LZCS input — see r_recip_est row below).
 *   - `ac_gte_gpf_scale` (line ~71) covers stage 4's `mtc2 IR0..3 + nop2 + gte_cmdw_gpf + mfc2 MAC1/2/3 + sra`.
 *     We do NOT call it for the symmetric reason: the normalize in-place semantics overwrite the input regs (r_sx/r_sy/r_sz) with the normalized output,
 *     which `ac_gte_gpf_scale`'s r_dx/r_dy/r_dz output GPRs would not match.
 *   `gte_cmdw_sqr` and `gte_cmdw_gpf` primitive macros ARE used in the inlined body, so changes to those primitives
 *   (e.g., the libgte `fake_cmd` signature bits) propagate automatically. The components remain available for callers that want the explicit GPR-shape variants.
 *
 * Argument aliasing (9 unique physical regs needed, can drop to 8 with r_sq_y ≡ r_lzcr):
 *   r_sx, r_sy, r_sz        : src components in regs (clobbered by mtc2 → IR1/2/3 in stage 1, then by mfc2 MAC1/2/3 in stage 4 — in-place semantics)
 *   r_sq_y, r_sq_z          : MAC2, MAC3 → DIE after stage 2 accumulate (r_sq_y can alias r_lzcr after stage 2 to save one reg)
 *   r_recip_est             : ≡ r_sqmag — multi-purpose (holds |v|² in stage 2, shift-input in stage 3, sqrtbl[index] in stage 4)
 *   r_lzcr                  : LZCR value, alive across stage 3 (srav path needs `24 - LZCR`)
 *   r_shift                 : (31 - LZCR & ~1) >> 1 — final srav amount (stages 3-4)
 *   r_tmp                   : scratch (shift count, branch target, lookup addr, table base)
 *
 * GPR ccount peak: 9.
 * Pipeline: clobbers IR0..3, MAC1..3, LZCS, LZCR.
 * Words: ~35 (pending re-gen; matches libgte 0x800160a0..0x8001615c at +/- 0-2 words for BD-slot reshuffling).
 * Sqrtbl: hardcoded to 0x800185B4 (libgte msc02.rel.data). Note: swapped to local. */
I_ Slice_MipsCode ac_normalize_v3s4(U4 r_sx, U4 r_sy, U4 r_sz, U4 r_sq_y, U4 r_sq_z, U4 r_recip_est, U4 r_lzcr, U4 r_shift, U4 r_tmp)
atom_dbg_skip MipsAtomComp_Proc_(ac_normalize_v3s4, {
	/* 9-arg signature — must be on one line so the metaprogram captures the full arg list.
	 *   r_sx, r_sy, r_sz        : in/out — src components, overwritten with normalized
	 *   r_sq_y, r_sq_z          : scratch — MAC2, MAC3 → die after stage 2 accumulate (r_sq_y may alias r_lzcr post-stage-2)
	 *   r_recip_est             : ≡ r_sqmag — multi-purpose (|v|² → shift-input → sqrtbl entry)
	 *   r_lzcr                  : LZCR value (alive across stage 3 srav path)
	 *   r_shift                 : (31 - LZCR & ~1) / 2 — final srav amount (stages 3-4)
	 *   r_tmp                   : scratch — shift count, branch target, lookup addr, table base
	 *
	 * GPR ccount peak: 9.
	 * Pipeline: clobbers IR0..3, MAC1..3, LZCS, LZCR.
	 * Words: ~35 (pending re-gen; matches libgte 0x800160a0..0x8001615c at +/- 0-2 words).
	 *
	 * Sqrtbl address: link-time constant `&gte_normalize_sqrtbl`, split via >>16 and &0xFFFF. */

	// ─── Stage 1: mtc2 src → IR1/2/3, SQR fires (MAC1/2/3 = IR², IR ← MAC saturated) ───
	// Componentized equivalent: mac_gte_sqr_v3(r_sx, r_sy, r_sz, r_sq_x, r_sq_y, r_sq_z).
	// We inline for GPR-pressure reasons (see file-level comment).
	gte_mv_to_data_r(r_sx, C2_IR1),
	gte_mv_to_data_r(r_sy, C2_IR2),
	gte_mv_to_data_r(r_sz, C2_IR3),
	nop, gte_cmdw_sqr,

	// ─── Stage 2: mfc2 MAC1/2/3, sum, mtc2 LZCS ───
	// Note: r_recip_est first used as the sum accumulator (= |v|²), which is also what LZCS needs.
	gte_mv_from_data_r(r_sq_y,      C2_MAC1), /* r_sq_y = MAC1 = sx² */
	gte_mv_from_data_r(r_sq_z,      C2_MAC2), /* r_sq_z = MAC2 = sy² */
	gte_mv_from_data_r(r_recip_est, C2_MAC3), /* r_recip_est = MAC3 = sz² */
	nop,                                      /* MFC2→GPR load delay (1 slot) */
	add_u(r_recip_est, r_recip_est, r_sq_z),  /* r_recip_est += sy² */
	add_u(r_recip_est, r_recip_est, r_sq_y),  /* r_recip_est += sx² (sum = |v|²) */
	gte_mv_to_data_r(  r_recip_est, C2_LZCS), /* LZCS = |v|² */
	nop2,
	gte_mv_from_data_r(r_lzcr, C2_LZCR),      /* r_lzcr = LZCR (count of leading bits) */
	nop,                                      /* MFC2→GPR load delay (1 slot) */

	// ─── Stage 3: compute shift amount, align |v|² to bit 24, lookup 1/|v| ───
	// Matches libgte `bltz +0x10 ; nop ; b +0x14 ; sllv t4,v0,t3` pattern:
	//   - bltz TAKEN  → nop (BD), jump to srav_path; sllv SKIPPED
	//   - bltz !TAKEN → nop (BD), b +0x14 jumps to aligned_done; sllv (BD of b) executes
	and_i(         r_lzcr, r_lzcr, -2),       /* r_lzcr &= ~1 (force even for halving) */
	li_s(          r_shift, 31),              /* r_shift = 31 */
	sub_s(         r_shift, r_shift, r_lzcr), /* r_shift = 31 - LZCR */
	shift_aright(  r_shift, r_shift,  1),     /* r_shift = (31 - LZCR) / 2 */
	add_si(        r_tmp,   r_lzcr, -24),     /* r_tmp = LZCR - 24 (signed, for branch) */
	branch_lt_zero(r_tmp, atom_offset(srav_path, aligned_done)), nop,
	jump_rel(             atom_offset(aligned_done, srav_path)),
	shift_lleft_var(r_recip_est, r_recip_est, r_tmp),     /* BD-slot of branch_equal: r_recip_est = |v|² << (LZCR - 24) */
	atom_label(srav_path)                                 /* SRAV path: |v|² is small (top bit < bit 24) */
	li_s(          r_tmp, 24),
	sub_s(         r_tmp, r_tmp, r_lzcr),                 /* r_tmp = 24 - LZCR */
	shift_aright_var(r_recip_est, r_recip_est, r_tmp),    /* r_recip_est = |v|² >> (24 - LZCR) */
atom_label(aligned_done)                                /* Both paths converge here with |v|² aligned to bit 24 */
	/* r_recip_est now holds |v|² aligned to bit 24 — convert to byte offset, -64 to skip zero pad. */
	add_si(        r_recip_est, r_recip_est, -64),
	shift_lleft(   r_recip_est, r_recip_est, 1),           /* r_recip_est *= 2 (half-word index) */
	/* Reference OUR local sqrtbl via &-address split. Compiler/linker resolves both halves. */
	load_upper_i(  r_tmp, u4_hi(& gte_normalize_sqr_tbl)), /* lui */
	or_i_self(     r_tmp, u4_lo(& gte_normalize_sqr_tbl)), /* ori */
	add_u(         r_tmp, r_tmp, r_recip_est),             /* r_tmp = sqrtbl base + byte offset (matches libgte 0x80016118: addu t5,t5,t4) */
	load_half(     r_recip_est, r_tmp, 0),                 /* r_recip_est = sqrtbl[r_recip_est] = 1/|v| estimate */
	nop,                                                   /* retire load_half before MTC2 (matches libgte 0x80016120: nop) */

	// ─── Stage 4: mtc2 IR0..3, GPF (MAC = IR0*IR), mfc2 MAC, srav finalize ───
	// Componentized equivalent: mac_gte_gpf_scale.
	gte_mv_to_data_r(r_recip_est, C2_IR0),  /* IR0 = 1/|v| estimate */
	gte_mv_to_data_r(r_sx,        C2_IR1),  /* IR1 = src.x */
	gte_mv_to_data_r(r_sy,        C2_IR2),  /* IR2 = src.y */
	gte_mv_to_data_r(r_sz,        C2_IR3),  /* IR3 = src.z */
	nop2,                                   /* COP2 transfer latency (2 slots) */
	gte_cmdw_gpf,
	gte_mv_from_data_r(r_sx, C2_MAC1),      /* MAC1 → r_sx (overwrites src.x with raw reciprocal-scaled) */
	gte_mv_from_data_r(r_sy, C2_MAC2),
	gte_mv_from_data_r(r_sz, C2_MAC3),
	shift_aright_var(r_sx, r_sx, r_shift),
	shift_aright_var(r_sy, r_sy, r_shift),
	shift_aright_var(r_sz, r_sz, r_shift),
})

#pragma endregion MACs (Mips Atom Components)

#pragma region Bsked Atoms

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
	load_word(R_T0, R_T3, 0),  load_word(R_T1, R_T3,  4),
	gte_mv_to_ctrl_r(R_T0, gte_cr_RT11), gte_mv_to_ctrl_r(R_T1, gte_cr_RT12),
	load_word(R_T0, R_T3, 8),  load_word(R_T1, R_T3, 12), load_word(R_T2, R_T3, 16),
	gte_mv_to_ctrl_r(R_T0, gte_cr_RT13), gte_mv_to_ctrl_r(R_T1, gte_cr_RT21), gte_mv_to_ctrl_r(R_T2, gte_cr_RT22),
	load_word(R_T0, R_T3, 20), load_word(R_T1, R_T3, 24), load_word(R_T2, R_T3, 28),
	gte_mv_to_ctrl_r(R_T0, gte_cr_TRX),  gte_mv_to_ctrl_r(R_T1, gte_cr_TRY),  gte_mv_to_ctrl_r(R_T2, gte_cr_TRZ),
	mac_yield()
};

#pragma endregion Baked Atoms
