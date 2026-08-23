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
#include "duffle/math.atom.h"
#include "duffle/mips.atom.c"
#include "duffle/gte.atom.h"
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
	MemTape_Len              = 512,

	ResolveLookAtArena_Words = 1024,
	ResolveLookAtArena_Size  = ResolveLookAtArena_Words * S_(MipsCode),

	CT_InitAtomMem_Words     = Kilo_(4),
	CT_InitAtomMem_Size       = CT_InitAtomMem_Words * S_(MipsCode),
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

	U1 ct_init_atom_mem[CT_InitAtomMem_Size];
	MipsAtom* normalize_v3s4;
	MipsAtom* gte_cross_v3s4;

	U1        resolve_look_at_mem[ResolveLookAtArena_Size];
	MipsAtom* resolve_look_at_bundle[AtomBundle_Len(resolve_look_at)];
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
	psy_normalize_v3s4(& forward, & uz);              // RGA(Lengyel): Normalize the direction bulk. Not finite-point unitization.

	cross_v3s4(& uz,   up_in, & right); psy_normalize_v3s4(& right, & ux); // RGA(Lengyel): Complement(Wedge(forward, up_in)) -> right axis.
	cross_v3s4(& uz, & ux,    & up);    psy_normalize_v3s4(& up,    & uy); // RGA(Lengyel): Complement(Wedge(forward, right)) -> up axis.

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

internal void compile_init_atoms(void) {
	AtomArena ab = atomarena_make(slice_ut_arr(smem.ct_init_atom_mem));
	RegFile   rf = regfile(regfile_abi_mask);
#define ralloc() regfile_alloc(& rf)
#define ralloc_v3() { ralloc(), ralloc(), ralloc() }

	smem.gte_cross_v3s4 = gte_cross_v3s4(& ab,
		RegUse_(gte_cross_v3s4) {
			.a     = ralloc_v3(),
			.b     = ralloc_v3(),
			.out   = ralloc(),
			.src_a = ralloc(),
			.src_b = ralloc(),
		});
	regfile_reset(& rf);

	smem.normalize_v3s4 = normalize_v3s4(& ab,
		RegUse_(normalize_v3s4) {
			.res = ralloc_v3(),
			.r0     = ralloc(),
			.r1     = ralloc(),
			.r2     = ralloc(),
			.r3     = ralloc(),
			.r4     = ralloc(),
			.r5     = ralloc(),
		});
	regfile_reset(& rf);

	assert(ab.used <= CT_InitAtomMem_Size);
#undef ralloc
#undef ralloc_v3
}

internal void compile_resolve_look_at(void) {
	AtomBundle_resolve_look_at_R bundle = C_(void*, smem.resolve_look_at_bundle);
	AtomArena ab = atomarena_make(slice_ut_arr(smem.resolve_look_at_mem));
	RegFile   rf = regfile(regfile_abi_mask);
#define ralloc() regfile_alloc(& rf)
#define ralloc_v3() { ralloc(), ralloc(), ralloc() }
	bundle->input_and_sub = AtomBundleEntry_(resolve_look_at, input_and_sub)(& ab,
		RegUse_(resolve_look_at_input_and_sub) {
			.target_ptr = ralloc(),
			.eye_ptr    = ralloc(),
			.up_in_ptr  = ralloc(),
			.up_in      = ralloc_v3(),
			.r012       = ralloc_v3(),
			.r345       = {ralloc(), R_AT, ralloc() },
	});
	regfile_reset(& rf);

	bundle->normalize_fwd_uz   = smem.normalize_v3s4;
	bundle->cross_to_right     = smem.gte_cross_v3s4;
	bundle->normalize_right_ux = smem.normalize_v3s4;
	bundle->cross_to_up        = smem.gte_cross_v3s4;
	bundle->normalize_up_uy    = smem.normalize_v3s4;

	bundle->populate_mt3s4s2 = AtomBundleEntry_(resolve_look_at,populate_mt3s4s2)(& ab,
		RegUse_(resolve_look_at_populate_mt3s4s2){
			.look_at = ralloc(),
			.eye     = ralloc(),
			.row     = ralloc_v3(),
			.r0      = ralloc(),
			.r1      = ralloc(),
			.r2      = ralloc(),
		});

	assert(ab.used <= ResolveLookAtArena_Size); // Sanity check: arena didn't overflow.
#undef ralloc
}

// Emit the resolve_look_at bundle into the tape. Called once per frame from update().
I_ void resolve_look_at(TapeBuilder_R tb,	MT3_S2S4* look_at, P3_S4* eye, P3_S4* target,	V3_S4* up_in) {
	/* Typed view of the scratchpad for field-address arithmetic. */
	ResolveLookAtScratch*        sp     = C_scratch(ResolveLookAtScratch*);
	AtomBundle_resolve_look_at_R bundle = C_(void*, smem.resolve_look_at_bundle);
	tb_emit(tb, bundle->input_and_sub); tb_bind_(tb, Binds_ResolveLookAtSub, 
		.target = target,
		.eye    = eye,
		.up_in  = up_in,
	);
	tb_emit(tb, bundle->normalize_fwd_uz); tb_bind_(tb, Binds_normalize_v3s4,
		.src_offset = O_(ResolveLookAtScratch,fwd),
		.dst_offset = O_(ResolveLookAtScratch,uz),
	);
	tb_emit(tb, bundle->cross_to_right); tb_bind_(tb, Binds_gte_cross_v3s4,
		.src_a = & sp->uz,
		.src_b = & sp->up_in,
		.out   = & sp->right,
	);
	tb_emit(tb, bundle->normalize_right_ux); tb_bind_(tb, Binds_normalize_v3s4, 
		.src_offset = O_(ResolveLookAtScratch,right),
		.dst_offset = O_(ResolveLookAtScratch,ux),
	);
	tb_emit(tb, bundle->cross_to_up); tb_bind_(tb, Binds_gte_cross_v3s4, 
		.src_a = & sp->uz,
		.src_b = & sp->ux,
		.out   = & sp->up,
	);
	tb_emit(tb, bundle->normalize_up_uy); tb_bind_(tb, Binds_normalize_v3s4,
		.src_offset = O_(ResolveLookAtScratch,up),
		.dst_offset = O_(ResolveLookAtScratch,uy),
	);
	tb_emit(tb, bundle->populate_mt3s4s2); tb_bind_(tb, Binds_ResolveLookAt_PopulateMT3S4S2, 
		.look_at = look_at,
	);
}
FI_ void camera_look_at(TapeBuilder_R tb, Camera* c, P3_S4* target, V3_S4* up_in) { resolve_look_at(tb, & c->look_at, & c->pos, target, up_in); }

void update(PrimitiveArena* pa, U4* ordering_buf) 
{
	TapeBuilder tb = tb_make(slice_ut_arr(smem.MemTape));

	// Pad Input
	{
		tb.used = 0; tb_scope_run(& tb) {
			// Grab latest state from bios.
			tb_emit_(pad_bios_snapshot);
				tb_data(& tb,   u4_(& smem.pad_raw[0]));
				tb_data(& tb, u4_(& smem.pad[0]));
			// tb_emit_(pad_bios_snapshot);
			// 	tb_data_(raw,   & smem.pad_raw[1]);
			// 	tb_data_(state, & smem.pad[1]);

			tb_emit_(pad_input_cam);
				tb_data(& tb, u4_(& smem.pad[0]));
				tb_data(& tb, u4_(& smem.cam));

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

	if (pos->y + 150 > smem.floor.pos.y) vel->y *= -1;

	// Prep
	S4 nclip = 0;
	S4 orderingtbl_z = 0;
	A2_S2 p; //???
	S4 flag; //????

	B4 use_c11_path = false;
	if (use_c11_path) {
		camera_look_at_c11(& smem.cam, & smem.cube.pos, & v3s4(0, -fp_one, 0));
	}
	if (use_c11_path == false)
	{
		tb.used = 0; tb_scope_run(& tb) {
			camera_look_at(& tb, & smem.cam, & smem.cube.pos, & v3s4(0, -fp_one, 0));
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
		tape_run(tb_slice(tb));// Fire off the tape (bigger-clobber variant).

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
		tape_run(tb_slice(tb));// Fire off the tape (bigger-clobber variant).

		// C-side state (pa->used) has already been updated by the tape!
		// smem.floor.rot.y += 5;
	}
}

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

int main(void)
{
	smem = (SMemory){0};
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

		compile_init_atoms();
		compile_resolve_look_at();

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
