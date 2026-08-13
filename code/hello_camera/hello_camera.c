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
	ResolveLookAtArena_Words = 512,
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

	U4        resolve_look_at_mem[ResolveLookAtArena_Words];
	MipsAtom* resolve_look_at_atom_addrs[9];
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

void
resolve_look_at_c11(MT3_S2S4* look_at, P3_S4* eye, P3_S4* target, V3_S4* up_in) {
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
internal void resolve_look_at_init(void) {
	/* Wrap the static arena in a MipsAtomBuilder. */
	AtomArena ab = atomarena_make(slice_ut_arr(smem.resolve_look_at_mem));

	/* Atom 0: resolve_look_at__input_and_sub — stages eye/up_in into scratchpad,
	 * computes fwd = target - eye; binds R_ResolveScratch (R_T4) as the wave-context carrier for atoms 1-6.
	 * The body hardcodes R_AT and R_V0 as eye.y/eye.z temps (the existing sub_u(eye.x, eye.y, eye.z) chain from the prior Task 12.7 design). */
	smem.resolve_look_at_atom_addrs[0] = resolve_look_at__input_and_sub_proc(& ab, R_ResolveScratch,
		R_T0,  /* r_target_ptr (popped from tape) */
		R_T1,  /* r_eye_ptr    (popped from tape) */
		R_T2,  /* r_up_in_ptr  (popped from tape) */
		R_T3, R_T5, R_T6,  R_T7); /* r_tmp<0-3> */

	/* Atom 1: normalize_v3s4_proc
	 * The proc takes r_src_offset + r_dst_offset as U4 PARAMETERS — we pass the O_(...) macros here (evaluating to numeric literals 0 and 16).
	 * Body is identical across the 3 call sites (atoms 1, 3, 5); only the offset args differ.
	 * GPR pool: r_scratch (R_T4 carrier) + 9 body GPRs = 10.
	 *   r_src_ptr      (R_T0) : src ptr
	 *   r_dst_ptr      (R_T1) : dst ptr
	 *   r_tmp          (R_T2) : src.x PRESERVED (NOT clobbered by mfc2 MAC2) → fed to IR1 in stage 4
	 *   r_mac1_scratch (R_T3) : MAC1 scratch + aligned |v|² in stage 3
	 *   r_mac2_scratch (R_T5) : MAC2 scratch → result.x after stage 4 sra
	 *   r_recip_est    (R_T6) : src.y → result.y
	 *   r_lzcr         (R_T7) : |v|² accumulator + shift count + 1/|v| (overwritten across stages 2-4)
	 *   r_shift        (R_V0) : shift count (saved in stage 3) → sra amount in stage 4
	 *   r_branch_tmp   (R_V1) : src.z → result.z (reused after stage 1)
	 */
	ab.start = ab.start + ab.used;
	smem.resolve_look_at_atom_addrs[1] = normalize_v3s4_proc(& ab, R_ResolveScratch,
		O_(ResolveLookAtScratch, fwd),          /* r_src_offset = 0 */
		O_(ResolveLookAtScratch, uz),           /* r_dst_offset = 16 */
		R_T0, R_T1, R_T2,                       /* r_src_ptr, r_dst_ptr, r_tmp */
		R_T3,                                   /* r_mac1_scratch */
		R_T5,                                   /* r_mac2_scratch */
		R_T6,                                   /* r_recip_est */
		R_T7,                                   /* r_lzcr */
		R_V0,                                   /* r_shift */
		R_V1);                                  /* r_branch_tmp */

	/* Atom 2: resolve_look_at__cross_uz_up_in_to_right
	 * out=scratch+32 (HARDCODED in body). GPR pool: r_scratch + 7 body + R_AT + R_V0 = 10. */
	smem.resolve_look_at_atom_addrs[2] = resolve_look_at__cross_uz_up_in_to_right_proc(& ab, R_ResolveScratch,
		R_T0, R_T1, R_T2, /* r_a, r_b, r_c (a.x/y/z → out.x/y/z) */
		R_T3,             /* r_d (b.x) */
		R_T5,             /* r_f (out ptr = scratch+32) */
		R_T6,             /* r_g (a ptr = scratch+16) */
		R_T7);            /* r_h (b ptr = scratch+128) */

	/* Atom 3: normalize_v3s4_proc. */
	smem.resolve_look_at_atom_addrs[3] = normalize_v3s4_proc(& ab, R_ResolveScratch,
		O_(ResolveLookAtScratch, right), /* r_src_offset = 32 */
		O_(ResolveLookAtScratch, ux),    /* r_dst_offset = 48 */
		R_T0, R_T1, R_T2,
		R_T3,
		R_T5,
		R_T6,
		R_T7,
		R_V0,
		R_V1);

	/* Atom 4: resolve_look_at__cross_uz_ux_to_up — a=scratch+16, b=scratch+48, out=scratch+64 (HARDCODED). */
	smem.resolve_look_at_atom_addrs[4] = resolve_look_at__cross_uz_ux_to_up_proc(& ab, R_ResolveScratch,
		R_T0, R_T1, R_T2,
		R_T3,
		R_T5,  /* r_f (out ptr = scratch+64) */
		R_T6,  /* r_g (a ptr = scratch+16) */
		R_T7); /* r_h (b ptr = scratch+48) */

	/* Atom 5: normalize_v3s4_proc (generic, from gte.atom.c) — src=scratch+64=up, dst=scratch+80=uy. */
	smem.resolve_look_at_atom_addrs[5] = normalize_v3s4_proc(& ab, R_ResolveScratch,
		O_(ResolveLookAtScratch, up), /* r_src_offset = 64 */
		O_(ResolveLookAtScratch, uy), /* r_dst_offset = 80 */
		R_T0, R_T1, R_T2,
		R_T3,
		R_T5,
		R_T6,
		R_T7,
		R_V0,
		R_V1);

	/* Atom 6: resolve_look_at__populate_and_translate — write look_at->m[][] from ux/uy/uz (computed from r_scratch+offset internally),
	then compute translation column t[] = R * (-eye). GPR pool: r_look_at + r_scratch + 4 ptr regs + 3 tmp regs = 9. */
	smem.resolve_look_at_atom_addrs[6] = resolve_look_at__populate_proc(& ab,
		R_T0,                    /* r_look_at (popped from tape; MT3_S2S4*) */
		R_ResolveScratch,        /* r_scratch (wave-context carrier) */
		R_T1, R_T3, R_T5,        /* r_pux, r_puy, r_puz (no r_peye — 6a doesn't read eye) */
		R_T2, R_T6, R_V0);       /* r_tmp0, r_tmp1, r_tmp2 */
	ab.start = ab.start + ab.used;

	/* Atom 6b: resolve_look_at__matrix_vector - GTE MVMVA off = R * (-eye). Stores off to scratch+96. */
	smem.resolve_look_at_atom_addrs[7] = resolve_look_at__matrix_vector_proc(& ab,
		R_ResolveScratch,        /* r_scratch (wave-context carrier) */
		R_T1,                    /* r_peye (reused as off destination) */
		R_T0, R_T2, R_T3);       /* r_tmp0, r_tmp1, r_tmp2 */
	ab.start = ab.start + ab.used;

	/* Atom 6c: resolve_look_at__trans_matrix - copy scratch+96 (off) → look_at->t[]. */
	smem.resolve_look_at_atom_addrs[8] = resolve_look_at__trans_matrix_proc(& ab,
		R_T0,                    /* r_look_at (popped from tape; MT3_S2S4*) */
		R_ResolveScratch,        /* r_scratch (wave-context carrier) */
		R_T1,                    /* r_off_ptr = &scratch.eye */
		R_T2);                   /* r_tmp0 (transfer reg) */

	/* Sanity check: arena didn't overflow. */
	assert(ab.used <= ResolveLookAtArena_Words);
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
	// /* Atom 6b: matrix_vector — no tape-data (reads eye from scratch, writes off to scratch+96). */
	// tb_emit(tb, smem.resolve_look_at_atom_addrs[7]); { }
	// /* Atom 6c: trans_matrix — pop look_at* for the matrix destination. */
	// tb_emit(tb, smem.resolve_look_at_atom_addrs[8]); {
	// 	tb_data(tb, u4_(look_at)); /* Binds_ResolveLookAtPopAndTrans.look_at (MT3_S2S4*) */
	// }
}

FI_ void camera_look_at_c11(Camera* c, P3_S4* target, V3_S4* up_in) { resolve_look_at_c11(& c->look_at, & c->pos, target, up_in); }

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

	if (0) {
		camera_look_at_c11(& smem.cam, & smem.cube.pos, & v3s4(0, -fp_one, 0));
	}
	if (1)
	{
		tb.used = 0; tb_scope_run(& tb) {
			resolve_look_at(& tb, & smem.cam.look_at, & smem.cam.pos, & smem.cube.pos, & v3s4(0, -fp_one, 0));
		}
		V3_S4 right, up, forward;
		V3_S4 ux, uy, uz;
		V3_S4 pos, off;

		ResolveLookAtScratch_V scratch = C_scratch(ResolveLookAtScratch_V);

		// Atom 0: Works (tape emits fwd to scratch+0; C-side reads it back)
		forward = scratch->fwd;
		uz      = scratch->uz;
		right   = scratch->right;
		ux      = scratch->ux;
		up      = scratch->up;     // ← atom 4's output (replaces C-side cross_v3s4)
		uy      = scratch->uy;     // ← atom 5's output (replaces C-side normalize_v3s4)

		// cross_v3s4(& uz, & ux, & up); normalize_v3s4(& up, & uy);
		
		// Atom 6 not yet enabled: populate look_at.m[][] from ux/uy/uz here.
		// smem.cam.look_at.m[0][0] = ux.x; smem.cam.look_at.m[0][1] = ux.y; smem.cam.look_at.m[0][2] = ux.z;
		// smem.cam.look_at.m[1][0] = uy.x; smem.cam.look_at.m[1][1] = uy.y; smem.cam.look_at.m[1][2] = uy.z;
		// smem.cam.look_at.m[2][0] = uz.x; smem.cam.look_at.m[2][1] = uz.y; smem.cam.look_at.m[2][2] = uz.z;

		// pos = smem.cam.pos; mul_v3s4(& pos, v3s4(-1,-1,-1)); // RGA(Lengyel): -eye in world coordinates (spatial bulk only; implicit weight is dropped).

		mul_m3s2_v3s4(& smem.cam.look_at, & pos, & off);
		trans_m3s2(   & smem.cam.look_at,        & off);
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

