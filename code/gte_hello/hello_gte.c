#include "stdio.h"
#include <stdlib.h>
#include "assert.h"
// #include "libgpu.h"
// #include "libetc.h"
// #include "libgte.h"

#include "duffle/dsl.h"
#include "duffle/memory.h"
#include "duffle/math.h"
#include "duffle/gcc_asm.h"
#include "duffle/mips.h"
#include "duffle/gp.h"
#include "duffle/gte.h"

#	include "duffle/gen/lottes_tape.offsets.h"
#include "duffle/atom_dsl.h"
#include "duffle/lottes_tape.h"

#	include "tape_atom.metadata.h"
#	include "gen/hello_gte_tape.offsets.h"
#include "hello_gte.h"
#include "hello_gte_tape.c"

typedef U4 OrderingTable_Buffer[OrderingTbl_Len];
typedef Array_(OrderingTable_Buffer, 2);

typedef B1 PrimitiveBuffer[PrimitiveBuff_Len];
typedef Array_(PrimitiveBuffer, 2);
typedef Struct_(PrimitiveArena) {
	A2_PrimitiveBuffer buf;
	U4                 used;
};

#define Cube_num_verts 8
typedef Array_(V3_S2, Cube_num_verts);
#define Cube_num_faces 6
typedef Array_(V4_S2, Cube_num_faces);
I_ void ent_cube128_init(A8_V3_S2* verts, A6_V4_S2* faces) {
	LP_ A8_V3_S2 baked_verts = (A8_V3_S2) {
		{ -128, -128, -128 },
		{  128, -128, -128 },
		{  128, -128,  128 },
		{ -128, -128,  128 },
		{ -128,  128, -128 },
		{  128,  128, -128 },
		{  128,  128,  128 },
		{ -128,  128,  128 }
	};
	LP_ A6_V4_S2 baked_faces = (A6_V4_S2) {
		{ 3, 2, 0, 1 },
		{ 0, 1, 4, 5 },
		{ 4, 5, 7, 6 },
		{ 1, 2, 5, 6 },
		{ 2, 3, 6, 7 },
		{ 3, 0, 7, 4 },
	};
	mem_copy(u4_(verts), u4_(& baked_verts), S_(A8_V3_S2) );
	mem_copy(u4_(faces), u4_(& baked_faces), S_(A6_V4_S2) );
	return;
}
typedef Struct_(Ent_Cube) {
	V3_S4 accel;
	V3_S4 vel;
	V3_S4 pos;
	V3_S4 scale;
	V3_S2 rot;
	A8_V3_S2 verts;
	A6_V4_S2 faces;
};

#define Floor_num_verts 4
typedef Array_(V3_S2, Floor_num_verts);
#define Floor_num_faces 2
typedef Array_(V3_S2, Floor_num_faces);
I_ void ent_floor_init(A4_V3_S2* verts, A2_V3_S2* faces) {
	LP_ A4_V3_S2 baked_verts = (A4_V3_S2) {
		{ -900, 0, -900 },
		{ -900, 0,  900 },
		{  900, 0, -900 },
		{  900, 0,  900 },
	};
	LP_ A2_V3_S2 baked_faces = (A2_V3_S2) {
		{ 0, 1, 2 },
		{ 1, 3, 2 },
	};
	mem_copy(u4_(verts), u4_(& baked_verts), S_(A4_V3_S2));
	mem_copy(u4_(faces), u4_(& baked_faces), S_(A2_V3_S2));
};
typedef Struct_(Ent_Floor) {
	V3_S4 accel;
	V3_S4 pos;
	V3_S4 scale;
	V3_S2 rot;
	A4_V3_S2 verts;
	A2_V3_S2 faces;
};

enum { scratchpad_size = 1024, };
typedef Struct_(SMemory) {
	DoubleBuffer            screen_buf;
	A2_OrderingTable_Buffer ordering_tbl;
	PrimitiveArena          primitives;
	S4                      active_buf_id;

	M3_S2 tform_world;

	Ent_Cube  cube;
	Ent_Floor floor;

	U4_V scratchpad; // d-cache
};
global SMemory smem;
extern SMemory smem;

// TODO(Ed):
FI_ U4* spad_warm(MipsAtom atom) {
	return nullptr;
}

I_ B1* prim__alloc(U4 type_width, Str8 type_name) {
	gknown PrimitiveArena* pa  = & smem.primitives;
	gknown B1*             buf = (B1*) r_(smem.primitives.buf)[smem.active_buf_id];
	assert(pa->used + type_width < PrimitiveBuff_Len);
	B1* next  = buf + pa->used;
	pa->used += type_width;
	return next;
}
#define prim_alloc(type) (type*)prim__alloc(S_(type), slit( stringify(type)))

void gp_screen_init_c11(DoubleBuffer* screen_buf, S4* active_buf_id)
{
	reset_graph(0);

	// Set the current initial buffer
	active_buf_id[0] = 0;

	// Just setting env data, not interacting with console hw.
	// First buffer area
	displayenv_init(& r_(screen_buf->display)[0], 0, 0,           ScreenRes_X, ScreenRes_Y);
	drawenv_init   (& r_(screen_buf->draw   )[0], 0, ScreenRes_Y, ScreenRes_X, ScreenRes_Y);
	// Second buffer area
	displayenv_init(& r_(screen_buf->display)[1], 0, ScreenRes_Y, ScreenRes_X, ScreenRes_Y);
	drawenv_init   (& r_(screen_buf->draw   )[1], 0, 0,           ScreenRes_X, ScreenRes_Y);
	// Set the back/drawing buffer
	screen_buf->draw[0].enable_auto_clear = true;
	screen_buf->draw[1].enable_auto_clear = true;
	// Set the background clear color
	screen_buf->draw[0].initial_bg_color = rgb8( .r = 7, .g = 7,  .b = 7 );
	screen_buf->draw[1].initial_bg_color = rgb8( .r = 7, .g = 7,  .b = 7 );
	// screen_buf->draw[1].initial_bg_color = rgb8( .r = 47, .g = 13, .b = 0 );
	displayenv_put(& r_(screen_buf->display)[ active_buf_id[0] ]);
	drawenv_put   (& r_(screen_buf->draw   )[ active_buf_id[0] ]);

	// Initialize and setup the GTE geometry offsets
	geom_init();
	geom_set_offset(ScreenRes_CenterX, ScreenRes_CenterY);
	geom_set_screen(ScreenZ);

	set_display_enabled(1); // gp_DisplayEnabled
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

void render(void) {
}

void update(PrimitiveArena* pa, U4* ordering_buf) 
{
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

	// Draw Cube
	if (1)
	{
		m3s2_rotation   (& smem.cube.rot,    & smem.tform_world);
		m3s2_translation(& smem.tform_world, & smem.cube.pos);
		m3s2_scale      (& smem.tform_world, & smem.cube.scale);
		gte_matrix_set_rotation   (& smem.tform_world);
		gte_matrix_set_translation(& smem.tform_world);
		for (U4 face_id = 0; face_id < Cube_num_faces; face_id += 1)
		{
			Poly_G4* quad = prim_alloc(Poly_G4); set_poly_g4(quad);
			quad->c0 = rgb8(255,   0, 255);
			quad->c1 = rgb8(255, 255,   0);
			quad->c2 = rgb8(  0, 255, 255);
			quad->c3 = rgb8(  0, 255,   0);

			V4_S2* face = & smem.cube.faces[face_id];
			V3_S2* p0   = & smem.cube.verts[face->x];
			V3_S2* p1   = & smem.cube.verts[face->y];
			V3_S2* p2   = & smem.cube.verts[face->z];
			V3_S2* p3   = & smem.cube.verts[face->w];

			nclip = rtp_avg_nclip_a4_v3s2(
				p0, p1, p2, p3,
				& quad->p0, & quad->p1, & quad->p2, & quad->p3,
				& p, & orderingtbl_z, & flag
			);
			if (nclip <= 0) {
				continue;
			}

			if ((orderingtbl_z > 0) && (orderingtbl_z < OrderingTbl_Len)) {
				orderingtbl_add_primitive(ordering_buf[orderingtbl_z], quad);
			}
		}
		// smem.cube.rot.x +=  6;
		// smem.cube.rot.y +=  8;
		// smem.cube.rot.z += 12;
		smem.cube.rot.y += 30;
	}
	// Draw cube (tape method) - two triangles per face
	if (0)
	{
		m3s2_rotation   (& smem.cube.rot,    & smem.tform_world);
		m3s2_translation(& smem.tform_world, & smem.cube.pos);
		m3s2_scale      (& smem.tform_world, & smem.cube.scale);
		gte_matrix_set_rotation   (& smem.tform_world);
		gte_matrix_set_translation(& smem.tform_world);

		U4 prim_base   = u4_(pa->buf[smem.active_buf_id]);
		U4 prim_cursor = prim_base + pa->used;

		LP_ U4 mem_temp_tape[512]; FArena tape_arena; farena_init(& tape_arena, slice_ut_arr(mem_temp_tape));
		TapeBuilder tb = tb_make_old(&tape_arena); tb_scope(& tb) {
			tb_emit(& tb, code_rbind_cube_tri);
				tb_data(& tb, prim_cursor);
				tb_data(& tb, u4_(smem.cube.faces));
				tb_data(& tb, u4_(smem.cube.verts));
				tb_data(& tb, u4_(ordering_buf));

			for (U4 i = 0; i < Cube_num_faces; i++) {
				// Two triangles per quad face: (x,y,z) and (x,z,w)
				tb_emit(& tb, code_cube_tri);
			}

			tb_emit(& tb, code_sync_primitive_arena);
				tb_data(& tb, u4_(& pa->used));
				tb_data(& tb, prim_base);
		}
		tape_run(tb_slice(tb));

		smem.cube.rot.y += 30;
	}
	// Draw Floor
	if (0)
	{
		m3s2_rotation   (& smem.floor.rot,   & smem.tform_world);
		m3s2_translation(& smem.tform_world, & smem.floor.pos);
		m3s2_scale      (& smem.tform_world, & smem.floor.scale);
		gte_matrix_set_rotation   (& smem.tform_world);
		gte_matrix_set_translation(& smem.tform_world);
		for (U4 face_id = 0; face_id < Floor_num_faces; face_id += 1)
		{
			Poly_F3* tri = prim_alloc(Poly_F3); set_poly_f3(tri);
			tri->color   = rgb8(255, 255, 255);

			V3_S2* face = & smem.floor.faces[face_id];
			register V3_S2* p0 rgcc(R_T4) = & smem.floor.verts[face->x];
			register V3_S2* p1 rgcc(R_T5) = & smem.floor.verts[face->y];
			register V3_S2* p2 rgcc(R_T6) = & smem.floor.verts[face->z];

			// Three independent bases — full register discretion at the call site
			gte_load_v0(p0, R_T4);
			/*
			asm volatile( ".word " "%0" ", %1" : : 
				"i"(((op_lwc2 & OPCODE_MASK) << OPCODE_SHIFT) | ((R_T4 & REG_MASK) << RS_SHIFT) | ((gte_in_v0_xy & REG_MASK) << RT_SHIFT) | (0            & IMM_MASK)),
				"i"(((op_lwc2 & OPCODE_MASK) << OPCODE_SHIFT) | ((R_T4 & REG_MASK) << RS_SHIFT) | ((gte_in_v0_z  & REG_MASK) << RT_SHIFT) | (GTE_Z_Offset & IMM_MASK)), 
				"r"(p0) : 
				"$2", "$8", "$9", "$31", "memory" 
			);
			*/
			gte_load_v1(p1, R_T5);
			gte_load_v2(p2, R_T6);

			gte_rtpt();
			gte_nclip();
			gte_stotz(& nclip);

			// nclip = rtp_avg_nclip_a3_v3s2(p0, p1, p2
			// 	, & tri->p0, & tri->p1, & tri->p2
			// 	, & p, & orderingtbl_z, & flag
			// );
			// if (nclip <= 0) {
			// 	continue;
			// }

			if (nclip > 0 ) {
				gte_stsxy3(& tri->p0, & tri->p1, & tri->p2);
				gte_avsz3();
				gte_stotz(& orderingtbl_z);

				if ((orderingtbl_z > 0) && (orderingtbl_z < OrderingTbl_Len)) {
					orderingtbl_add_primitive(ordering_buf[orderingtbl_z], tri);
				}
			}
		}
		smem.floor.rot.y += 5;
	}
	// Draw floor tape method
	if (1)
	{
		m3s2_rotation   (& smem.floor.rot,   & smem.tform_world);
		m3s2_translation(& smem.tform_world, & smem.floor.pos);
		m3s2_scale      (& smem.tform_world, & smem.floor.scale);
		gte_matrix_set_rotation   (& smem.tform_world);
		gte_matrix_set_translation(& smem.tform_world);

		U4 prim_base   = u4_(pa->buf[smem.active_buf_id]);
		U4 prim_cursor = prim_base + pa->used;

		// TODO(Ed): We should do a bounds check beforehand to confirm pa can hold all tris.
		// The tape atoms in-flight should not need to care.

		// Prepare the tape. (Push protocol to tape)
		LP_ U4 mem_temp_tape[512];
		TapeBuilder tb = tb_make(slice_ut_arr(mem_temp_tape)); tb_scope(& tb) {
			// TODO(Ed): This is bugged.
			// tb_emit(& tb, code_set_gte_world);
			// 	tb_data(& tb, u4_(& smem.tform_world));

			tb_emit(& tb, code_rbind_floor_tri);
			// TODO(Ed): Just use a single context struct ref
				tb_data(& tb, prim_cursor);
				tb_data(& tb, u4_(smem.floor.faces));
				tb_data(& tb, u4_(smem.floor.verts));
				tb_data(& tb, u4_(ordering_buf));
			for (U4 i = 0; i < Floor_num_faces; i++) {
				tb_emit(& tb, code_floor_tri);
			}
			// After code_floor_tri iterations complete, the primitive arena's used counter needs updating.
			tb_emit(& tb, code_sync_primitive_arena);
				tb_data(& tb, u4_(& pa->used));
				tb_data(& tb, prim_base);
		}

		tape_run(tb_slice(tb));// Fire off the tape.

		// C-side state (pa->used) has already been updated by the tape!
		smem.floor.rot.y += 5;
	}
	// --- TAPE DIAGNOSTICS ---
	if (0)
	{
		LP_ U4 mem_temp_tape[512]; FArena tape_arena; farena_init(& tape_arena, slice_ut_arr(mem_temp_tape));
		TapeBuilder tb = tb_make_old(& tape_arena); tb_scope(& tb) {
			// Skip set_gte_world atom for diagnostics to isolate the triangle loop
			for (U4 i = 0; i < Floor_num_faces; i++) {
				// =======================================================
				// SWAP EMIT TO TEST DIFFERENT PARTS OF THE PIPELINE:
				// =======================================================
				// 1. code_diag_yield -> Tests Tape Engine jump logic
				// 2. code_diag_color -> Tests OT and Prim Arena memory
				// 3. code_diag_gte   -> Tests Vertex arrays and GTE Math
				// tb_emit(& tb, code_diag_yield);
				// tb_emit(& tb, code_diag_color); //TODO(Ed): Stopped working
				// tb_emit(& tb, code_diag_gte); 
			}
		}
		B1* prim_cursor = (B1*)r_(pa->buf)[smem.active_buf_id] + pa->used;
		tape_run(tb_slice(tb));
		pa->used = (U4)prim_cursor - (U4)r_(pa->buf)[smem.active_buf_id];
		smem.floor.rot.y += 5;
	}
}

int main(void)
{
	smem = (SMemory){0};
	smem.scratchpad = C_(U4_V, 0x1F800000);
	smem.primitives.used = 0;
	ent_cube128_init(& smem.cube.verts, & smem.cube.faces); {
		Ent_Cube* cube = & smem.cube;
		cube->rot    = v3s2(0, 0, 0);
		// cube->pos    = v3s4(0, 0, 900);
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
	// gknown gp_screen_init();
	gp_screen_init_c11(& smem.screen_buf, & smem.active_buf_id);
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
