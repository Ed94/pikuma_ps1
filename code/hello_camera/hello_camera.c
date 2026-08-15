#pragma region Vendors
#include <stdio.h>
#include <stdlib.h>
// #include <assert.h>
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
 * 4 unique procs in hello_camera.atom.c (chain atoms 0, 2, 4, 6); atoms 1, 3, 5
 * share the GENERIC normalize_v3s4_proc from gte.atom.c
 * 	0: resolve_look_at__input_and_sub_proc
 * 	1: normalize_v3s4_proc                  (fwd → uz; offsets 0, 16)
 * 	2: resolve_look_at__cross_uz_up_in_to_right_proc
 * 	3: normalize_v3s4_proc                  (right → ux; offsets 32, 48)
 * 	4: resolve_look_at__cross_uz_ux_to_up_proc
 * 	5: normalize_v3s4_proc                  (up → uy; offsets 64, 80)
 * 	6: resolve_look_at__populate_and_translate_proc
 */
internal void resolve_look_at_init(void) {
	/* Wrap the static arena in a MipsAtomBuilder. */
	AtomArena   ab = atomarena_make(slice_ut_arr(smem.resolve_look_at_mem));
	TapeBuilder tb = tb_make(slice_ut_arr(smem.resolve_look_at_atom_addrs));

	U4 pin_mask = regfile_abi_mask | (1 << R_ResolveScratch);
	RegFile rf  = regfile(pin_mask);

	smem.resolve_look_at_atom_addrs[0] = resolve_look_at__input_and_sub_proc(& ab,
		RegUse_(resolve_look_at__input_and_sub_proc) {
			.scratch = R_ResolveScratch,
			.target  = regfile_alloc(& rf),
			.eye     = regfile_alloc(& rf),
			.up_in   = regfile_alloc(& rf),
			.t0      = regfile_alloc(& rf),
			.t1      = regfile_alloc(& rf),
			.t2      = regfile_alloc(& rf),
			.t3      = regfile_alloc(& rf),
			.t4      = regfile_alloc(& rf),
		}
	);

	/* === ATOM 1: normalize fwd→uz === */
	U2 src_offset  = O_(ResolveLookAtScratch, fwd);
	U2 dst_offset  = O_(ResolveLookAtScratch, uz);
	smem.resolve_look_at_atom_addrs[1] = normalize_v3s4_proc(& ab,
		src_offset, dst_offset, RegUse_(normalize_v3s4_proc){
			.scratch   = R_ResolveScratch,
			.src_ptr   = R_T0, 
			.dst_ptr   = R_T1,
			.recip_est = R_T6, 
			.norm      = R_T7,
			.shift     = R_V0,
			.src_x     = R_T2,
			.t3 = R_T3,
			.t4 = R_T5,
			.t5 = R_V1,
		});

	/* === ATOM 2: cross uz×up_in→right === */
	smem.resolve_look_at_atom_addrs[2] = resolve_look_at__cross_uz_up_into_right_proc(& ab,
		RegUse_(resolve_look_at__cross_uz_up_into_right_proc) {
			.scratch = R_ResolveScratch,
			.a = R_T0, .b = R_T1, .c = R_T2,
			.d = R_T3,
			.f = R_T5,
			.t1 = R_T6,
			.t2 = R_T7,
			.t0 = R_V0,
		});

	/* === ATOM 3: normalize right→ux === */
	src_offset  = O_(ResolveLookAtScratch, right);
	dst_offset  = O_(ResolveLookAtScratch, ux);
	smem.resolve_look_at_atom_addrs[3] = normalize_v3s4_proc(& ab,
		src_offset, dst_offset, RegUse_(normalize_v3s4_proc){
			.scratch   = R_ResolveScratch,
			.src_ptr   = R_T0,
			.dst_ptr   = R_T1,
			.recip_est = R_T6,
			.norm      = R_T7,
			.shift     = R_V0,
			.src_x     = R_T2,
			.t3 = R_T3,
			.t4 = R_T5,
			.t5 = R_V1,
		});

	/* === ATOM 4: cross uz×ux→up === */
	U4 r_a_4 = R_T0;
	U4 r_b_4 = R_T1;
	U4 r_c_4 = R_T2;
	U4 r_d_4 = R_T3;
	U4 r_f_4 = R_T5;  /* out ptr (HARDCODED: scratch+64) */
	U4 r_g_4 = R_T6;  /* a ptr = scratch+16 */
	U4 r_h_4 = R_T7;  /* b ptr = scratch+48 */
	smem.resolve_look_at_atom_addrs[4] = resolve_look_at__cross_uz_ux_to_up_proc(& ab,
		R_ResolveScratch,
		r_a_4, r_b_4, r_c_4, r_d_4, r_f_4, r_g_4, r_h_4);

	/* === ATOM 5: normalize up→uy === */
	src_offset = O_(ResolveLookAtScratch, up);
	dst_offset = O_(ResolveLookAtScratch, uy);
	smem.resolve_look_at_atom_addrs[5] = normalize_v3s4_proc(& ab,
		src_offset, dst_offset,
		RegUse_(normalize_v3s4_proc){
			.scratch   = R_ResolveScratch,
			.src_ptr   = R_T0,
			.dst_ptr   = R_T1,
			.recip_est = R_T6,
			.norm      = R_T7,
			.shift     = R_V0,
			.src_x     = R_T2,
			.t3 = R_T3,
			.t4 = R_T5,
			.t5 = R_V1,
		});

	/* === ATOM 6a: populate (m[][] from ux/uy/uz, t[]=0) === */
	U4 r_look_at_6a = R_T0;  /* tape pop → look_at* */
	U4 r_scratch_6a = R_ResolveScratch;
	U4 r_pux_6a      = R_T1;
	U4 r_puy_6a      = R_T3;
	U4 r_puz_6a      = R_T5;
	U4 r_tmp0_6a     = R_T2;
	U4 r_tmp1_6a     = R_T6;
	U4 r_tmp2_6a     = R_V0;
	smem.resolve_look_at_atom_addrs[6] = resolve_look_at__populate_proc(& ab,
		r_look_at_6a, r_scratch_6a,
		r_pux_6a, r_puy_6a, r_puz_6a,
		r_tmp0_6a, r_tmp1_6a, r_tmp2_6a);

	/* === ATOM 6a.5: set_gte_mt3s2s4 (BAKED — ctc2 RT matrix) ===
	 * This is a BAKED atom from gte.atom.c. Its body hardcodes R_T3 as
	 * the matrix pointer (popped from tape). It does NOT need GPR
	 * assignment from us — it has its own internal GPR usage.
	 * We just take its address. */
	smem.resolve_look_at_atom_addrs[7] = (MipsAtom*) & set_gte_mt3s2s4;

	/* === ATOM 6b: matrix_vector (RT * (-eye) >> 12) ===
	 * Uses mac_apply_matrix_lv component macro which internally uses
	 * r_t0 for the RT matrix load + V0 load, then r_t0/r_t1/r_t2
	 * for the mfc2/store. We pass our GPRs. */
	U4 r_scratch_6b = R_ResolveScratch;
	U4 r_peye_6b    = R_T1;  /* scratch+96 (packed V0 dst, then off dst) */
	U4 r_look_at_6b = R_T0;  /* tape pop → look_at* */
	U4 r_tmp0_6b    = R_T2;
	U4 r_tmp1_6b    = R_T3;
	U4 r_tmp2_6b    = R_T5;
	smem.resolve_look_at_atom_addrs[8] = resolve_look_at__matrix_vector_proc(& ab,
		r_scratch_6b, r_peye_6b, r_look_at_6b,
		r_tmp0_6b, r_tmp1_6b, r_tmp2_6b);

	/* === ATOM 6c: trans_matrix (off → look_at->t[]) === */
	U4 r_look_at_6c = R_T0;  /* tape pop → look_at* */
	U4 r_scratch_6c = R_ResolveScratch;
	U4 r_off_ptr_6c = R_T1;  /* &scratch.eye (= off dst) */
	U4 r_tmp0_6c    = R_T2;
	smem.resolve_look_at_atom_addrs[9] = resolve_look_at__trans_matrix_proc(& ab,
		r_look_at_6c, r_scratch_6c, r_off_ptr_6c, r_tmp0_6c, R_T3, R_T4);

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
	tb_emit(tb, smem.resolve_look_at_atom_addrs[0]); {
		tb_data(tb, u4_(target));
		tb_data(tb, u4_(eye));
		tb_data(tb, u4_(up_in));
		tb_data(tb, u4_(smem.scratchpad));
	}

	tb_emit(tb, smem.resolve_look_at_atom_addrs[1]); { }
	tb_emit(tb, smem.resolve_look_at_atom_addrs[2]); { }
	tb_emit(tb, smem.resolve_look_at_atom_addrs[3]); { }
	tb_emit(tb, smem.resolve_look_at_atom_addrs[4]); { }
	tb_emit(tb, smem.resolve_look_at_atom_addrs[5]); { }

	tb_emit(tb, smem.resolve_look_at_atom_addrs[6]); {
		tb_data(tb, u4_(look_at));
	}
	tb_emit(tb, smem.resolve_look_at_atom_addrs[7]); {
		tb_data(tb, u4_(look_at));
	}
	tb_emit(tb, smem.resolve_look_at_atom_addrs[8]); {
		tb_data(tb, u4_(look_at));
	}
	tb_emit(tb, smem.resolve_look_at_atom_addrs[9]); {
		// tb_data(tb, u4_(look_at));
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
			// tb_emit_(pad_bios_snapshot);
			// 	tb_data_(raw,   & smem.pad_raw[1]);
			// 	tb_data_(state, & smem.pad[1]);

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
			cube->accel  = v3s4(0, 1, 0);
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

