#pragma region Vendors
#include <stdio.h>
#include <stdlib.h>
#include <assert.h>
// #include "libgpu.h"
// #include "libetc.h"
// #include "libgte.h"
#pragma endregion Vendors

#pragma region Duffle Headers
#	include "duffle/gen/macs.h"
#	include "duffle/gen/offsets.h"

#include "duffle/word_count.metadata.h"

#include "duffle/dsl.h"
#include "duffle/memory.h"
#include "duffle/math.h"

#include "duffle/gcc_asm.h"
#include "duffle/mips.h"
#include "duffle/gp.h"
#include "duffle/gte.h"
#include "duffle/pad.h"

#include "duffle/dsl.atom.h"
#include "duffle/lottes_tape.h"

#include "duffle/bios.h"
#include "duffle/psyq.h"
#pragma endregion Duffle Headers

#pragma region Duffle TUs
#include "duffle/pad.c"
#include "duffle/math.atom.c"
#include "duffle/mips.atom.c"
#include "duffle/gte.atom.c"
#include "duffle/gp.atom.c"
#include "duffle/pad.atom.c"
#include "duffle/psyq.atom.c"
#pragma endregion Duffle TUs

#pragma region Hello Camera Headers
#	include "gen/macs.h"
#	include "gen/offsets.h"
#	include "gen/auto_reg.h"

#include "hello_camera.h"
#pragma endregion Hello Camera Headers

#pragma region Hello Joypad TUs
#include "hello_camera.atom.c"
#pragma endregion Hello Joypad TUs

enum {
	Scratchpad_Loc = 0x1F800000,
};
#define C_scratch(type) C_(type, Scratchpad_Loc)

enum {
	Scratchpad_Len           = 1024,
	MemTape_Len              = 512,
	ResolveLookAtArena_Words = 1024,
	ResolveLookAtArena_Size  = ResolveLookAtArena_Words * S_(MipsCode),
};
typedef Struct_(SMemory) {
	PrimitiveArena          primitives;
	A2_OrderingTable_Buffer ordering_tbl;
	DoubleBuffer            screen_buf;
	S4                      active_buf_id;

	U4 MemTape[MemTape_Len];

	MT3_S2S4 tform_world;
	MT3_S2S4 tform_view;

	Camera cam;

	Ent_Cube  cube;
	Ent_Floor floor;

	PadBiosRaw pad_raw[2];
	PadState   pad[2];

	// TODO(Ed): We don't need this we can just cast at any point an address to a desired view of scratchpad, we have the address.
	U4_V scratchpad; // d-cache

	U1        resolve_look_at_mem[ResolveLookAtArena_Size];
	MipsAtom* resolve_look_at_atom_addrs[10];
};
global SMemory smem;
extern SMemory smem;

#define pad0_btn_(btn) btn & smem.pad[0].buttons
#define pad1_btn_(btn) btn & smem.pad[1].buttons

I_ B1* prim__alloc(U4 type_width, Str8 type_name) {
	gknown PrimitiveArena* pa  = & smem.primitives;
	gknown B1*             buf = (B1*) r_(smem.primitives.buf)[smem.active_buf_id];
	assert(pa->used + type_width < PrimitiveBuff_Len);
	B1* next  = buf + pa->used;
	pa->used += type_width;
	return next;
}
#define prim_alloc(type) (type*)prim__alloc(S_(type), slit( stringify(type)))

I_ void resolve_look_at_c11(MT3_S2S4* look_at, P3_S4* eye, P3_S4* target, V3_S4* up_in) {
// RGA(Lengyel): Build matrix expansion of a rigid transformation. Corresponding motor is not constructed; we write the LA form for GTE.
// Preconditions: eye != target, up_in not collinear with (target - eye).
	V3_S4 right, up, forward;
	V3_S4 ux, uy, uz;
	V3_S4 pos, off;

	forward = target[0]; sub_v3s4(& forward, eye[0]); // RGA(Lengyel): Affine point - point = zero-weight direction.
	normalize_v3s4(& forward, & uz);                  // RGA(Lengyel): Normalize the direction bulk. Not finite-point unitization.

	cross_v3s4(& uz,   up_in, & right); normalize_v3s4(& right, & ux); // RGA(Lengyel): Complement(Wedge(forward, up_in)) -> right axis.
	cross_v3s4(& uz, & ux,    & up);    normalize_v3s4(& up,    & uy); // RGA(Lengyel): Complement(Wedge(forward, right)) -> up axis.

	// RGA(Lengyel): matrix expansion of the world-to-camera rotation (basis rows).
	look_at->m[0][0] = ux.x; look_at->m[0][1] = ux.y; look_at->m[0][2] = ux.z;
	look_at->m[1][0] = uy.x; look_at->m[1][1] = uy.y; look_at->m[1][2] = uy.z;
	look_at->m[2][0] = uz.x; look_at->m[2][1] = uz.y; look_at->m[2][2] = uz.z;

	pos = eye[0]; mul_v3s4(& pos, v3s4(-1,-1,-1)); // RGA(Lengyel): -eye in world coordinates (spatial bulk only; implicit weight is dropped).

	// RGA(Lengyel): R * (-eye) is the full matrix translation column. 
	// Motor translator would store half this displacement in m.xyz; GTE consumes full column.
	mul_m3s2_v3s4(look_at, & pos, & off);
	trans_m3s2(   look_at,        & off);
}
FI_ void camera_look_at_c11(Camera* c, P3_S4* target, V3_S4* up_in) { resolve_look_at_c11(& c->look_at, & c->pos, target, up_in); }

/* Pre-build all 7 chain atoms of the resolve_look_at bundle into the static arena.
 * Called ONCE from main() before the frame loop.
 * After this returns, the smem.resolve_look_at_atom_addrs[] array contains valid MIPS atom pointers
 * for the frame-time bundle helper to emit via tb_emit(tb, captured_addr).
 *
 * 4 unique procs in hello_camera.atom.c (chain atoms 0, 2, 4, 6); atoms 1, 3, 5
 * share the GENERIC normalize_v3s4_proc from gte.atom.c (called 3x with different
 * O_(ResolveLookAtScratch,...) offsets):
 * 	0: resolve_look_at__input_and_sub_proc
 * 	1: normalize_v3s4_proc                  (fwd → uz; offsets 0, 16)
 * 	2: resolve_look_at__cross_uz_up_in_to_right_proc
 * 	3: normalize_v3s4_proc                  (right → ux; offsets 32, 48)
 * 	4: resolve_look_at__cross_uz_ux_to_up_proc
 * 	5: normalize_v3s4_proc                  (up → uy; offsets 64, 80)
 * 	6: resolve_look_at__populate_and_translate_proc
 *
 * Task 12.16 promotion: the bundle-specific resolve_look_at__chain_normalize_proc
 * has been promoted to the generic normalize_v3s4_proc (gte.atom.c), which now
 * takes r_scratch + r_src_offset + r_dst_offset as U4 parameters. The 3 callers
 * pass O_(ResolveLookAtScratch,...) macros as offset args. The metaprogram emits
 * one set of `atom_offset__normalize_v3s4__srav_path__aligned_done` defs
 * (namespaced by atom name) in duffle/gen/offsets.h, shared by all 3 callers.
 *
 * GPR pool per atom: 10 free GPRs (R_T0..R_T3 + R_T5..R_T7 + R_V0 + R_V1 + R_AT).
 * R_T4 is reserved as the wave-context carrier (R_ResolveScratch).
 */
/* === EXPLICIT REGISTER ALLOCATION TRACKER ===
 * Every GPR used by every atom is tracked below. NO GPR is assigned to
 * two atoms at overlapping lifetimes. The tape runtime preserves R_T8/R_T9
 * (R_AtomJmp/R_TapePtr) and clobbers R_T0-R_T7, R_AT, R_V0, R_V1.
 * R_T4 is reserved as R_ResolveScratch (wave-context carrier).
 *
 * GPR pool: R_T0($8), R_T1($9), R_T2($10), R_T3($11), R_T5($13),
 *           R_T6($14), R_T7($15), R_V0($2), R_V1($3), R_AT($1)
 * Reserved: R_T4($12) = R_ResolveScratch
 * Tape: R_T8($24) = R_AtomJmp, R_T9($25) = R_TapePtr (preserved)
 *
 * === ATOM 0: input_and_sub (stages eye/up_in, computes fwd) ===
 * Pop tape → R_T0(target), R_T1(eye), R_T2(up_in).
 * Use R_T3,R_T5,R_T6,R_T7 as temps.
 * NO conflict with other atoms (each atom has independent lifetime).
 *
 * === ATOM 1: normalize fwd→uz ===
 * r_src_offset=0, r_dst_offset=16.
 * r_src_ptr=R_T0, r_dst_ptr=R_T1, r_tmp=R_T2 (preserved for stage 4).
 * r_mac1=R_T3, r_mac2=R_T5, r_recip=R_T6, r_lzcr=R_T7, r_shift=R_V0, r_branch=R_V1.
 *
 * === ATOM 2: cross uz×up_in→right ===
 * r_a=R_T0, r_b=R_T1, r_c=R_T2, r_d=R_T3, r_f(out)=R_T5, r_g=R_T6, r_h=R_T7.
 *
 * === ATOM 3: normalize right→ux ===
 * Same GPR pool as atom 1.
 *
 * === ATOM 4: cross uz×ux→up ===
 * r_a=R_T0, r_b=R_T1, r_c=R_T2, r_d=R_T3, r_f(out)=R_T5, r_g=R_T6, r_h=R_T7.
 *
 * === ATOM 5: normalize up→uy ===
 * Same GPR pool as atom 1.
 *
 * === ATOM 6a: populate (m[][] from ux/uy/uz, t[]=0) ===
 * r_look_at=R_T0 (pop tape), r_scratch=R_T4.
 * r_pux=R_T1, r_puy=R_T3, r_puz=R_T5.
 * r_tmp0=R_T2, r_tmp1=R_T6, r_tmp2=R_V0.
 *
 * === ATOM 6a.5: set_gte_mt3s2s4 (ctc2 RT matrix) ===
 * BAKED atom. Uses R_T3 internally (hardcoded in gte.atom.c).
 * NO conflict — different GPR pool, and the atom body hardcodes R_T3
 * as the matrix pointer. We DON'T need to assign R_T3 to atom 6a.5
 * because it's a baked atom with its own GPR usage.
 *
 * === ATOM 6b: matrix_vector (RT * (-eye) >> 12) ===
 * r_look_at=R_T0 (pop tape), r_scratch=R_T4.
 * r_peye=R_T1.
 * r_tmp0=R_T2, r_tmp1=R_T3, r_tmp2=R_T5.
 * Uses mac_apply_matrix_lv which internally uses these temps.
 *
 * === ATOM 6c: trans_matrix (off → look_at->t[]) ===
 * r_look_at=R_T0 (pop tape), r_scratch=R_T4.
 * r_off_ptr=R_T1.
 * r_tmp0=R_T2.
 *
 * === CONFLICT CHECK ===
 * All atoms use the same GPR pool R_T0-R_T3, R_T5-R_T7, R_V0-R_V1.
 * But atoms are SEQUENTIAL — each atom's lifetime is disjoint from
 * the next atom's lifetime. The tape yield handshake between atoms
 * preserves R_TapePtr (R_T9) and R_AtomJmp (R_T8).
 *
 * The GPR pool is SHARED across atoms (they run sequentially, not
 * concurrently). Each atom's build call assigns specific R_T* codes
 * for that atom's body. The same R_T* code can be reused across atoms
 * because the previous atom's body has already yielded.
 */
internal void resolve_look_at_init(void) {
	/* Wrap the static arena in a MipsAtomBuilder. */
	AtomArena ab = atomarena_make(slice_ut_arr(smem.resolve_look_at_mem));

	/* === ATOM 0: input_and_sub === */
	U4 const r_target_ptr = R_T0;  /* tape pop → target */
	U4 const r_eye_ptr    = R_T1;  /* tape pop → eye */
	U4 const r_up_in_ptr  = R_T2;  /* tape pop → up_in */
	U4 const r_tmp0_0     = R_T3;
	U4 const r_tmp1_0     = R_T5;
	U4 const r_tmp2_0     = R_T6;
	U4 const r_tmp3_0     = R_T7;
	smem.resolve_look_at_atom_addrs[0] = resolve_look_at__input_and_sub_proc(& ab,
		R_ResolveScratch,
		r_target_ptr, r_eye_ptr, r_up_in_ptr,
		r_tmp0_0, r_tmp1_0, r_tmp2_0, r_tmp3_0);

	/* === ATOM 1: normalize fwd→uz === */
	ab.start = ab.start + ab.used;
	U4 const r_src_offset_1  = O_(ResolveLookAtScratch, fwd);
	U4 const r_dst_offset_1  = O_(ResolveLookAtScratch, uz);
	U4 const r_src_ptr_1     = R_T0;
	U4 const r_dst_ptr_1     = R_T1;
	U4 const r_tmp_1         = R_T2;
	U4 const r_mac1_1        = R_T3;
	U4 const r_mac2_1        = R_T5;
	U4 const r_recip_1       = R_T6;
	U4 const r_lzcr_1        = R_T7;
	U4 const r_shift_1       = R_V0;
	U4 const r_branch_1      = R_V1;
	smem.resolve_look_at_atom_addrs[1] = normalize_v3s4_proc(& ab,
		R_ResolveScratch,
		r_src_offset_1, r_dst_offset_1,
		r_src_ptr_1, r_dst_ptr_1, r_tmp_1,
		r_mac1_1, r_mac2_1, r_recip_1, r_lzcr_1,
		r_shift_1, r_branch_1);

	/* === ATOM 2: cross uz×up_in→right === */
	U4 const r_a_2 = R_T0;
	U4 const r_b_2 = R_T1;
	U4 const r_c_2 = R_T2;
	U4 const r_d_2 = R_T3;
	U4 const r_f_2 = R_T5;  /* out ptr (HARDCODED in body: scratch+32) */
	U4 const r_g_2 = R_T6;  /* a ptr = scratch+16 */
	U4 const r_h_2 = R_T7;  /* b ptr = scratch+128 */
	smem.resolve_look_at_atom_addrs[2] = resolve_look_at__cross_uz_up_in_to_right_proc(& ab,
		R_ResolveScratch,
		r_a_2, r_b_2, r_c_2, r_d_2, r_f_2, r_g_2, r_h_2);

	/* === ATOM 3: normalize right→ux === */
	U4 const r_src_offset_3  = O_(ResolveLookAtScratch, right);
	U4 const r_dst_offset_3  = O_(ResolveLookAtScratch, ux);
	U4 const r_src_ptr_3     = R_T0;
	U4 const r_dst_ptr_3     = R_T1;
	U4 const r_tmp_3         = R_T2;
	U4 const r_mac1_3        = R_T3;
	U4 const r_mac2_3        = R_T5;
	U4 const r_recip_3       = R_T6;
	U4 const r_lzcr_3        = R_T7;
	U4 const r_shift_3       = R_V0;
	U4 const r_branch_3      = R_V1;
	smem.resolve_look_at_atom_addrs[3] = normalize_v3s4_proc(& ab,
		R_ResolveScratch,
		r_src_offset_3, r_dst_offset_3,
		r_src_ptr_3, r_dst_ptr_3, r_tmp_3,
		r_mac1_3, r_mac2_3, r_recip_3, r_lzcr_3,
		r_shift_3, r_branch_3);

	/* === ATOM 4: cross uz×ux→up === */
	U4 const r_a_4 = R_T0;
	U4 const r_b_4 = R_T1;
	U4 const r_c_4 = R_T2;
	U4 const r_d_4 = R_T3;
	U4 const r_f_4 = R_T5;  /* out ptr (HARDCODED: scratch+64) */
	U4 const r_g_4 = R_T6;  /* a ptr = scratch+16 */
	U4 const r_h_4 = R_T7;  /* b ptr = scratch+48 */
	smem.resolve_look_at_atom_addrs[4] = resolve_look_at__cross_uz_ux_to_up_proc(& ab,
		R_ResolveScratch,
		r_a_4, r_b_4, r_c_4, r_d_4, r_f_4, r_g_4, r_h_4);

	/* === ATOM 5: normalize up→uy === */
	U4 const r_src_offset_5  = O_(ResolveLookAtScratch, up);
	U4 const r_dst_offset_5  = O_(ResolveLookAtScratch, uy);
	U4 const r_src_ptr_5     = R_T0;
	U4 const r_dst_ptr_5     = R_T1;
	U4 const r_tmp_5         = R_T2;
	U4 const r_mac1_5        = R_T3;
	U4 const r_mac2_5        = R_T5;
	U4 const r_recip_5       = R_T6;
	U4 const r_lzcr_5        = R_T7;
	U4 const r_shift_5       = R_V0;
	U4 const r_branch_5      = R_V1;
	smem.resolve_look_at_atom_addrs[5] = normalize_v3s4_proc(& ab,
		R_ResolveScratch,
		r_src_offset_5, r_dst_offset_5,
		r_src_ptr_5, r_dst_ptr_5, r_tmp_5,
		r_mac1_5, r_mac2_5, r_recip_5, r_lzcr_5,
		r_shift_5, r_branch_5);

	/* === ATOM 6a: populate (m[][] from ux/uy/uz, t[]=0) === */
	U4 const r_look_at_6a = R_T0;  /* tape pop → look_at* */
	U4 const r_scratch_6a = R_ResolveScratch;
	U4 const r_pux_6a      = R_T1;
	U4 const r_puy_6a      = R_T3;
	U4 const r_puz_6a      = R_T5;
	U4 const r_tmp0_6a     = R_T2;
	U4 const r_tmp1_6a     = R_T6;
	U4 const r_tmp2_6a     = R_V0;
	smem.resolve_look_at_atom_addrs[6] = resolve_look_at__populate_proc(& ab,
		r_look_at_6a, r_scratch_6a,
		r_pux_6a, r_puy_6a, r_puz_6a,
		r_tmp0_6a, r_tmp1_6a, r_tmp2_6a);

	/* === ATOM 6a.5: set_gte_mt3s2s4 (BAKED — ctc2 RT matrix) ===
	 * This is a BAKED atom from gte.atom.c. Its body hardcodes R_T3 as
	 * the matrix pointer (popped from tape). It does NOT need GPR
	 * assignment from us — it has its own internal GPR usage.
	 * We just take its address. */
	smem.resolve_look_at_atom_addrs[9] = (MipsAtom*) & set_gte_mt3s2s4;

	/* === ATOM 6b: matrix_vector (RT * (-eye) >> 12) ===
	 * Uses mac_apply_matrix_lv component macro which internally uses
	 * r_t0 for the RT matrix load + V0 load, then r_t0/r_t1/r_t2
	 * for the mfc2/store. We pass our GPRs. */
	U4 const r_scratch_6b = R_ResolveScratch;
	U4 const r_peye_6b    = R_T1;  /* scratch+96 (packed V0 dst, then off dst) */
	U4 const r_look_at_6b = R_T0;  /* tape pop → look_at* */
	U4 const r_tmp0_6b    = R_T2;
	U4 const r_tmp1_6b    = R_T3;
	U4 const r_tmp2_6b    = R_T5;
	smem.resolve_look_at_atom_addrs[7] = resolve_look_at__matrix_vector_proc(& ab,
		r_scratch_6b, r_peye_6b, r_look_at_6b,
		r_tmp0_6b, r_tmp1_6b, r_tmp2_6b);

	/* === ATOM 6c: trans_matrix (off → look_at->t[]) === */
	U4 const r_look_at_6c = R_T0;  /* tape pop → look_at* */
	U4 const r_scratch_6c = R_ResolveScratch;
	U4 const r_off_ptr_6c = R_T1;  /* &scratch.eye (= off dst) */
	U4 const r_tmp0_6c    = R_T2;
	smem.resolve_look_at_atom_addrs[8] = resolve_look_at__trans_matrix_proc(& ab,
		r_look_at_6c, r_scratch_6c, r_off_ptr_6c, r_tmp0_6c);

	/* Sanity check: arena didn't overflow. */
	assert(ab.used <= ResolveLookAtArena_Size);
}

/* Emit the resolve_look_at bundle into the tape. Called once per frame from update().
 * The 7 chain atoms are pre-built at init time (resolve_look_at_init) and referenced by address via smem.resolve_look_at_atom_addrs[].
 * Per-frame work: 7 tb_emit (atom pointer emissions) + 5 tb_data (C-side pointers for atom 0 + look_at for atom 6).
 *
 * Binds_ contract (the field-name labels are for human readability):
 *   Atom 0  input_and_sub              target(4) eye(4) up_in(4) scratch_base(4) = 4 words
 *   Atoms 1-5                           (no tape data — atom uses r_scratch + offset internally)
 *   Atom 6  populate_and_translate     look_at(4)                                = 1 word
 *                                       ----
 *                                       5 tb_data words total per frame.
 */
I_ void resolve_look_at(
		TapeBuilder_R tb
	,	MT3_S2S4* look_at
	,	P3_S4*    eye
	,	P3_S4*    target
	,	V3_S4*    up_in
){
	// tb_emit_bundle(tb, slice_from_array(MipsAtom, smem.resolve_look_at_atom_addrs));

	/* Atom 0: input_and_sub — stages eye/up_in into scratchpad + computes fwd.  */
	tb_emit(tb, smem.resolve_look_at_atom_addrs[0]); {
		tb_data(tb, u4_(target));              /* Binds_ResolveLookAtSub.target  (C-side P3_S4*) */
		tb_data(tb, u4_(eye));                 /* Binds_ResolveLookAtSub.eye     (C-side P3_S4*) */
		tb_data(tb, u4_(up_in));               /* Binds_ResolveLookAtSub.up_in   (C-side V3_S4*) */
		tb_data(tb, u4_(smem.scratchpad));     /* Binds_ResolveLookAtScratch.scratch_base */
	}

	/* Atoms 1 + 2: enabled. */
	tb_emit(tb, smem.resolve_look_at_atom_addrs[1]); { }
	tb_emit(tb, smem.resolve_look_at_atom_addrs[2]); { }
	tb_emit(tb, smem.resolve_look_at_atom_addrs[3]); { }
	tb_emit(tb, smem.resolve_look_at_atom_addrs[4]); { }
	tb_emit(tb, smem.resolve_look_at_atom_addrs[5]); { }

	/* Atom 6a: populate — pop look_at* for the matrix destination. */
	tb_emit(tb, smem.resolve_look_at_atom_addrs[6]); {
		tb_data(tb, u4_(look_at)); /* Binds_ResolveLookAtPopAndTrans.look_at (MT3_S2S4*) */
	}
	/* Atom 6a.5: load_rt — pop look_at* again, ctc2 look_at->m[][] into GTE
	 * C2[0..4]. Pattern identical to set_gte_mt3s2s4 (proven correct for
	 * cube rendering via RTPT/RTPS). The mac_yield between atoms gives
	 * the GTE pipeline time to fully retire the ctc2s. */
	tb_emit(tb, smem.resolve_look_at_atom_addrs[9]); {
		tb_data(tb, u4_(look_at)); /* Binds_ResolveLookAtPopAndTrans.look_at (MT3_S2S4*) */
	}
	/* Atom 6b: matrix_vector — pops look_at* for mac_apply_matrix_lv (which loads
	 * the RT matrix from it). Reads eye from scratch, packs pos as SVECTOR,
	 * lwc2 into V0, RTPS (sf=1, v=0, cv=3, mx=0), stores MAC1/2/3 → scratch+96. */
	tb_emit(tb, smem.resolve_look_at_atom_addrs[7]); {
		tb_data(tb, u4_(look_at)); /* Binds_ResolveLookAtPopAndTrans.look_at (MT3_S2S4*) */
	}
	/* Atom 6c: trans_matrix — pop look_at* for the matrix destination. */
	tb_emit(tb, smem.resolve_look_at_atom_addrs[8]); {
		tb_data(tb, u4_(look_at)); /* Binds_ResolveLookAtPopAndTrans.look_at (MT3_S2S4*) */
	}
}

GCC_OPTIMIZATION_DISABLE
void update(PrimitiveArena* pa, U4* ordering_buf) 
{
	TapeBuilder tb = tb_make(slice_ut_arr(smem.MemTape));

	// Pad Input
	{
		tb.used = 0; tb_scope_run(& tb) {
			// Grab latest state from bios.
			tb_emit_(pad_bios_snapshot);
				tb_data_(raw,   & smem.pad_raw[0]);
				tb_data_(state, & smem.pad[0]);
			tb_emit_(pad_bios_snapshot);
				tb_data_(raw,   & smem.pad_raw[1]);
				tb_data_(state, & smem.pad[1]);

			tb_emit_(pad_input_cam);
				tb_data_(state, & smem.pad[0]);
				tb_data_(cam, & smem.cam);

			// tb_emit_(pad_input_cube_rotation);
			// 	tb_data_(state,     & smem.pad[0]);
			// 	tb_data_(cube_rot,  & smem.cube.rot);
			// 	tb_data_(floor_rot, & smem.floor.rot);
		}
	}

	orderingtbl_clear_reverse(ordering_buf, OrderingTbl_Len);

	// Update the position based on acceleration and velocity
	gknown V3_S4_R pos = & smem.cube.pos;
	gknown V3_S4_R vel = & smem.cube.vel;
	gknown V3_S4_R acc = & smem.cube.accel;
	add_v3s4(vel, acc[0]);
	add_v3s4_fp(pos, vel[0]);
	// vel->x += acc->x;
	// vel->y += acc->y;
	// vel->z += acc->z;
	// pos->x += vel->x;
	// pos->y += vel->y;
	// pos->z += vel->z;

	if (pos->y + 150 > smem.floor.pos.y) vel->y *= -1;

	// Prep
	S4 nclip = 0;
	S4 orderingtbl_z = 0;
	A2_S2 p;    //???
	S4 flag; //????

	B4 use_c11_path = false;
	if (use_c11_path) {
		camera_look_at_c11(& smem.cam, & smem.cube.pos, & v3s4(0, -fp_one, 0));
	}
	if (use_c11_path == false)
	{
		tb.used = 0; tb_scope_run(& tb) {
			resolve_look_at(& tb, & smem.cam.look_at, & smem.cam.pos, & smem.cube.pos, & v3s4(0, -fp_one, 0));
		}
		V3_S4 right, up, forward;
		V3_S4 ux, uy, uz;
		V3_S4 pos, off;

		ResolveLookAtScratch_V scratch = C_scratch(ResolveLookAtScratch_V);

		/* Atoms 0-5 emit into scratch; bundle dispatch for atom 6 is still
		* commented at the resolve_look_at_init helper. Until atom 6 is
		* enabled, populate look_at.m[][] from the wave-context outputs. */
		forward = scratch->fwd;
		uz      = scratch->uz;
		right   = scratch->right;
		ux      = scratch->ux;
		up      = scratch->up;
		uy      = scratch->uy;

		// pos = smem.cam.pos; mul_v3s4(& pos, v3s4(-1,-1,-1));

		// mul_m3s2_v3s4(& smem.cam.look_at, & pos, & off);
		// trans_m3s2(   & smem.cam.look_at,        & off);
	}

	// Draw cube
	if (1)
	{
		mt3s2s4_rotation   (& smem.cube.rot,    & smem.tform_world);
		mt3s2s4_translation(& smem.tform_world, & smem.cube.pos);
		mt3s2s4_scale      (& smem.tform_world, & smem.cube.scale);

		// Combine world and look_at matrix.
		gte_comp_coord_m3s2(& smem.cam.look_at, & smem.tform_world, & smem.tform_view);
		gte_matrix_set_rotation   (& smem.tform_view);
		gte_matrix_set_translation(& smem.tform_view);

		// gte_matrix_set_rotation   (& smem.tform_world);
		// gte_matrix_set_translation(& smem.tform_world);

		U4 prim_base   = u4_(pa->buf[smem.active_buf_id]);
		U4 prim_cursor = prim_base + pa->used;

		tb.used = 0; tb_scope(& tb) {
			tb_emit(& tb, rbind_cube_g4_face);
				tb_data(& tb, prim_cursor);
				tb_data(& tb, u4_(smem.cube.faces));
				tb_data(& tb, u4_(smem.cube.verts));
				tb_data(& tb, u4_(ordering_buf));

			for (U4 i = 0; i < Cube_num_faces; i++) {
				// Two triangles per quad face: (x,y,z) and (x,z,w)
				tb_emit(& tb, cube_g4_face);
			}

			tb_emit(& tb, sync_primitive_arena);
				tb_data(& tb, u4_(& pa->used));
				tb_data(& tb, prim_base);
		}
		tape_run_a02_s07(tb_slice(tb));// Fire off the tape (bigger-clobber variant).

		// smem.cube.rot.y += 30;
	}
	// Draw floor
	if (1)
	{
		mt3s2s4_rotation   (& smem.floor.rot,   & smem.tform_world);
		mt3s2s4_translation(& smem.tform_world, & smem.floor.pos);
		mt3s2s4_scale      (& smem.tform_world, & smem.floor.scale);

		// Combine world and look_at matrix.
		gte_comp_coord_m3s2(& smem.cam.look_at, & smem.tform_world, & smem.tform_view);

		gte_matrix_set_rotation   (& smem.tform_view);
		gte_matrix_set_translation(& smem.tform_view);

		U4 prim_base   = u4_(pa->buf[smem.active_buf_id]);
		U4 prim_cursor = prim_base + pa->used;

		// TODO(Ed): We should do a bounds check beforehand to confirm pa can hold all tris?
		// The tape atoms in-flight should not need to care.

		// Prepare the tape. (Push protocol to tape)
		tb.used = 0; tb_scope(& tb) {
			// tb_emit(& tb, set_gte_mt3s2s4);
			// 	tb_data(& tb, u4_(& smem.tform_view));

			tb_emit(& tb, rbind_floor_f3_face);
			// TODO(Ed): Just use a single context struct ref?
				tb_data(& tb, prim_cursor);
				tb_data(& tb, u4_(smem.floor.faces));
				tb_data(& tb, u4_(smem.floor.verts));
				tb_data(& tb, u4_(ordering_buf));
			for (U4 i = 0; i < Floor_num_faces; i++) {
				tb_emit(& tb, floor_f3_face);
			}
			// After floor_f3_face iterations complete, the primitive arena's used counter needs updating.
			tb_emit(& tb, sync_primitive_arena);
				tb_data(& tb, u4_(& pa->used));
				tb_data(& tb, prim_base);
		}
		tape_run_a02_s07(tb_slice(tb));// Fire off the tape (bigger-clobber variant).

		// C-side state (pa->used) has already been updated by the tape!
		// smem.floor.rot.y += 5;
	}
}
GCC_OPTIMIZATION_ENABLE

void render(void) {
}

void gp_display_frame(DoubleBuffer* screen_buf, S4* active_buf_id, U4* ordering_buf, PrimitiveArena* pa) {
	draw_sync(0);
	vsync(0);
	displayenv_put(& r_(screen_buf->display)[active_buf_id[0] ]);
	drawenv_put   (& r_(screen_buf->draw)   [active_buf_id[0] ]);
	{
		draw_orderingtbl(ordering_buf + OrderingTbl_Len - 1);
		pa->used = 0;
	}
	active_buf_id[0] = ! active_buf_id[0]; // Swap current buffer
}

GCC_OPTIMIZATION_DISABLE
int main(void)
{
	smem = (SMemory){0};
	// TODO(Ed): remove this field we don't need it in smem.
	smem.scratchpad = C_(U4_V, Scratchpad_Loc);
	// smem.primitives.used = 0;
	// smem.active_buf_id   = 0;
	smem.cam.pos = v3s4(500, -1000, -1500);
	/*Persistent Entity Setup*/{
		ent_cube128_init(& smem.cube.verts, & smem.cube.faces); {
			Ent_Cube* cube = & smem.cube;
			cube->rot    = v3s2(0, 0, 0);
			cube->scale  = v3s4_fp_one();
			cube->accel  = v3s4(0, 0, 0);
			cube->pos    = v3s4(0, -400, 1800);
		}
		ent_floor_init(& smem.floor.verts, & smem.floor.faces); {
			Ent_Floor* floor = & smem.floor;
			floor->rot   = v3s2(0, 0, 0);
			floor->pos   = v3s4(0, 450, 1800);
			floor->scale = v3s4_fp_one();
		}
	}
	TapeBuilder tb = tb_make(slice_ut_arr(smem.MemTape)); {
		reset_graph(0);
		/* Direct BIOS: poll both ports during VBlank. */
		pad_bios_init_start(& smem.pad_raw[0], & smem.pad_raw[1]);

		/* Pre-build the resolve_look_at bundle atoms into the static arena. */
		resolve_look_at_init();

		/* Pinned registers for the GPU init atom. */
		register U4*           io_base_addr rgcc(R_IO_BaseAddr) = u4_r(IO_BASE_ADDR);
		register DoubleBuffer* screen_buf   rgcc(R_ScreenBuf)   = & smem.screen_buf;
		tb.used = 0; tb_scope_run(& tb) {
			tb_emit(& tb, screen_env_init);
			tb_emit(& tb, gp_screen_init);
		}
	}
	while (1) {
		gknown S4* active_buf_id  = & smem.active_buf_id;
		gknown U4* ordering_buf   = r_(smem.ordering_tbl)[active_buf_id[0]];
		gknown PrimitiveArena* pa = & smem.primitives;
		update(pa, ordering_buf);
		render();
		gp_display_frame(& smem.screen_buf, active_buf_id, ordering_buf, pa);
	};
	return 0;
}
GCC_OPTIMIZATION_ENABLE

