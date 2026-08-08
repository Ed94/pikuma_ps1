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

#include "hello_camera.h"
#pragma endregion Hello Camera Headers

#pragma region Hello Joypad TUs
#include "hello_camera.atom.c"
#pragma endregion Hello Joypad TUs

enum { 
	Scratchpad_Len = 1024, 
	MemTape_Len    = 512,
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

	U4_V scratchpad; // d-cache
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
resolve_look_at_c11(MT3_S2S4* look_at, V3_S4* eye, V3_S4* target, V3_S4* up_in) {
// TODO(Ed): Want to interpret this under the lens of Eric Lengyel's geometric algebra
	V3_S4 right, up, forward;
	V3_S4 ux, uy, uz;
	V3_S4 pos, off;

	forward = target[0]; sub_v3s4(& forward, eye[0]);
	normalize_v3s4(& forward, & uz);

	cross_v3s4(& uz,   up_in, & right); normalize_v3s4(& right, & ux);
	cross_v3s4(& uz, & ux,    & up);    normalize_v3s4(& up,    & uy);

	look_at->m[0][0] = ux.x; look_at->m[0][1] = ux.y; look_at->m[0][2] = ux.z;
	look_at->m[1][0] = uy.x; look_at->m[1][1] = uy.y; look_at->m[1][2] = uy.z;
	look_at->m[2][0] = uz.x; look_at->m[2][1] = uz.y; look_at->m[2][2] = uz.z;
	
	pos = eye[0]; mul_v3s4(& pos, v3s4(-1,-1,-1));

	mul_m3s2_v3s4(look_at, & pos, & off);
	trans_m3s2(look_at, & off);
}

FI_ void camera_look_at_c11(Camera* c, V3_S4* target, V3_S4* up_in) { resolve_look_at_c11(& c->look_at, & c->pos, target, up_in); }

GCC_OPTIMIZATION_DISABLE
void update(PrimitiveArena* pa, U4* ordering_buf) 
{
	TapeBuilder tb = tb_make(slice_ut_arr(smem.MemTape));

	if (1) // Pad Input
	{
		tb.used = 0; tb_scope_run(& tb) {
			// Grab latest state from bios.
			tb_emit_(pad_bios_snapshot);
				tb_data_(raw,   & smem.pad_raw[0]);
				tb_data_(state, & smem.pad[0]);
			tb_emit_(pad_bios_snapshot);
				tb_data_(raw,   & smem.pad_raw[1]);
				tb_data_(state, & smem.pad[1]);

			// TODO(Ed): Implement based on below.
			tb_emit_(pad_input_cam);
				tb_data_(state, & smem.pad[0]);
				tb_data_(cam, & smem.cam);

			// if (pad0_btn_(Pad_Left)) {
			// 	smem.cam.pos.x -= 50;
			// }
			// if (pad0_btn_(Pad_Right)) {
			// 	smem.cam.pos.x += 50;
			// }
			// if (pad0_btn_(Pad_Up)) {
			// 	smem.cam.pos.y -= 50;
			// }
			// if (pad0_btn_(Pad_Down)) {
			// 	smem.cam.pos.y += 50;
			// }
			// if (pad0_btn_(Pad_Cross)) {
			// 	smem.cam.pos.z -= 50;
			// }
			// if (pad0_btn_(Pad_Circle)) {
			// 	smem.cam.pos.z += 50;
			// }


			// Demo input (not longer using)
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

	// Camera Look at
	if (1)
	{
		camera_look_at_c11(& smem.cam, & smem.cube.pos, & v3s4(0, -fp_one, 0));
	}
	// Camera look at (Tape)
	if (0)
	{
		tb.used = 0; tb_scope_run(& tb) {
			tb_emit_(resolve_look_at);
				// tb_data_();
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
		tape_run(tb_slice(tb));

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
		tape_run(tb_slice(tb));// Fire off the tape.

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
	smem.scratchpad = C_(U4_V, 0x1F800000);
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
