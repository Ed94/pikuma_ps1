#include "stdio.h"
#include <stdlib.h>
#include "assert.h"
// #include "libgpu.h"
// #include "libetc.h"
// #include "libgte.h"

#include "duffle/dsl.h"
#include "duffle/memory.h"
#include "duffle/math.h"
#include "duffle/gp.h"
#include "hello_gpu.h"

enum {
	PrimitiveBuff_Len = 4096,
	OrderingTbl_Len   = 2048
};

typedef U4 OrderingTable_Buffer[OrderingTbl_Len];
typedef def_farray(OrderingTable_Buffer, 2);

typedef B1 PrimitiveBuffer[PrimitiveBuff_Len];
typedef def_farray(PrimitiveBuffer, 2);
typedef def_struct(PrimitiveArena) {
	A2_PrimitiveBuffer buf;
	U4                 used;
};

#define Cube_num_verts 8
typedef def_farray(V3_S2, Cube_num_verts);
#define Cube_num_faces 6
typedef def_farray(V4_S2, Cube_num_faces);
void ent_cube128_init(A8_V3_S2* verts, A6_V4_S2* faces) {
	memory_copy(verts, & (A8_V3_S2) {
		{ -128, -128, -128 },
		{  128, -128, -128 },
		{  128, -128,  128 },
		{ -128, -128,  128 },
		{ -128,  128, -128 },
		{  128,  128, -128 },
		{  128,  128,  128 },
		{ -128,  128,  128 }
	}, size_of(A8_V3_S2) );
	memory_copy(faces, & (A6_V4_S2) {
		{ 3, 2, 0, 1 },
		{ 0, 1, 4, 5 },
		{ 4, 5, 7, 6 },
		{ 1, 2, 5, 6 },
		{ 2, 3, 6, 7 },
		{ 3, 0, 7, 4 },
	}, size_of(A6_V4_S2) );
	return;
}
typedef def_struct(Ent_Cube) {
	V3_S4 accel;
	V3_S4 vel;
	V3_S4 pos;
	V3_S4 scale;
	V3_S2 rot;
	A8_V3_S2 verts;
	A6_V4_S2 faces;
};

#define Floor_num_verts 4
typedef def_farray(V3_S2, Floor_num_verts);
#define Floor_num_faces 2
typedef def_farray(V3_S2, Floor_num_faces);
void ent_floor_init(A4_V3_S2* verts, A2_V3_S2* faces) {
	memory_copy(verts, &(A4_V3_S2) {
		{ -900, 0, -900 },
		{ -900, 0,  900 },
		{  900, 0, -900 },
		{  900, 0,  900 },
	}, size_of(A8_V3_S2));
	memory_copy(faces, & (A2_V3_S2) {
		{ 0, 1, 2 },
		{ 1, 3, 2 },
	}, size_of(A2_V3_S2));
};
typedef def_struct(Ent_Floor) {
	V3_S4 accel;
	V3_S4 pos;
	V3_S4 scale;
	V3_S2 rot;
	A4_V3_S2 verts;
	A2_V3_S2 faces;
};

typedef def_struct(SMemory) {
	DoubleBuffer            screen_buf;
	A2_OrderingTable_Buffer ordering_tbl;
	PrimitiveArena          primitives;
	S2                      active_buf_id;

	M3_S2 tform_world;

	Ent_Cube  cube;
	Ent_Floor floor;
};
global SMemory static_mem;
extern SMemory static_mem;

B1* prim__alloc(U4 type_width, Str8 type_name) {
	gknown PrimitiveArena* pa  = & static_mem.primitives;
	gknown B1*             buf = (B1*) r_(static_mem.primitives.buf)[static_mem.active_buf_id];
	assert(pa->used + type_width < PrimitiveBuff_Len);
	B1* next = buf + pa->used;
	pa->used += type_width;
	return next;
}
#define prim_alloc(type) (type*)prim__alloc(size_of(type), txt( stringify(type)))

void gp_screen_init_c11(DoubleBuffer* screen_buf, S2* active_buf_id)
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

void gp_display_frame(DoubleBuffer* screen_buf, S2* active_buf_id, U4* ordering_buf, PrimitiveArena* pa) {
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
	gknown V3_S4_R pos = & static_mem.cube.pos;
	gknown V3_S4_R vel = & static_mem.cube.vel;
	gknown V3_S4_R acc = & static_mem.cube.accel;
	add_v3s4(vel, acc[0]);
	add_v3s4_fp(pos, vel[0]);
	// vel->x += acc->x;
	// vel->y += acc->y;
	// vel->z += acc->z;
	// pos->x += vel->x;
	// pos->y += vel->y;
	// pos->z += vel->z;

	if (pos->y + 150 > static_mem.floor.pos.y) vel->y *= -1;

	// Prep
	S4 nclip = 0;
	S4 orderingtbl_z = 0;
	A2_S2 p;    //???
	S4 flag; //????

	// Draw Cube
	{
		m3s2_rotation   (& static_mem.cube.rot,    & static_mem.tform_world);
		m3s2_translation(& static_mem.tform_world, & static_mem.cube.pos);
		m3s2_scale      (& static_mem.tform_world, & static_mem.cube.scale);
		gte_matrix_set_rotation   (& static_mem.tform_world);
		gte_matrix_set_translation(& static_mem.tform_world);
		for (U4 face_id = 0; face_id < Cube_num_faces; face_id += 1)
		{
			Poly_G4* quad = prim_alloc(Poly_G4); set_poly_g4(quad);
			quad->c0 = rgb8(255,   0, 255);
			quad->c1 = rgb8(255, 255,   0);
			quad->c2 = rgb8(  0, 255, 255);
			quad->c3 = rgb8(  0, 255,   0);

			V4_S2* face = & static_mem.cube.faces[face_id];
			V3_S2* p0   = & static_mem.cube.verts[face->x];
			V3_S2* p1   = & static_mem.cube.verts[face->y];
			V3_S2* p2   = & static_mem.cube.verts[face->z];
			V3_S2* p3   = & static_mem.cube.verts[face->w];

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
		// static_mem.cube.rot.x +=  6;
		// static_mem.cube.rot.y +=  8;
		// static_mem.cube.rot.z += 12;
		static_mem.cube.rot.y += 20;
	}
	// Draw Floor
	{
		m3s2_rotation   (& static_mem.floor.rot,   & static_mem.tform_world);
		m3s2_translation(& static_mem.tform_world, & static_mem.floor.pos);
		m3s2_scale      (& static_mem.tform_world, & static_mem.floor.scale);
		gte_matrix_set_rotation   (& static_mem.tform_world);
		gte_matrix_set_translation(& static_mem.tform_world);
		for (U4 face_id = 0; face_id < Floor_num_faces; face_id += 1)
		{
			Poly_F3* tri = prim_alloc(Poly_F3); set_poly_f3(tri);
			tri->color   = rgb8(255, 255, 255);

			V3_S2* face = & static_mem.floor.faces[face_id];
			V3_S2* p0   = & static_mem.floor.verts[face->x];
			V3_S2* p1   = & static_mem.floor.verts[face->y];
			V3_S2* p2   = & static_mem.floor.verts[face->z];

			nclip = rtp_avg_nclip_a3_v3s2(p0, p1, p2
				, & tri->p0, & tri->p1, & tri->p2
				, & p, & orderingtbl_z, & flag
			);
			if (nclip <= 0) {
				continue;
			}

			if ((orderingtbl_z > 0) && (orderingtbl_z < OrderingTbl_Len)) {
				orderingtbl_add_primitive(ordering_buf[orderingtbl_z], tri);
			}
		}
		static_mem.floor.rot.y += 5;
	}
}

int main(void)
{
	static_mem = (SMemory){0};
	static_mem.primitives.used = 0;
	ent_cube128_init(& static_mem.cube.verts, & static_mem.cube.faces); {
		Ent_Cube* cube = & static_mem.cube;
		cube->rot    = v3s2(0, 0, 0);
		// cube->pos    = v3s4(0, 0, 900);
		cube->scale  = v3s4_fp_one();
		cube->accel  = v3s4(0, 1, 0);
		cube->pos    = v3s4(0, -400, 1800);
	}
	ent_floor_init(& static_mem.floor.verts, & static_mem.floor.faces); {
		Ent_Floor* floor = & static_mem.floor;
		floor->rot   = v3s2(0, 0, 0);
		floor->pos   = v3s4(0, 450, 1800);
		floor->scale = v3s4_fp_one();
	}
	// gknown gp_screen_init();
	gp_screen_init_c11(& static_mem.screen_buf, & static_mem.active_buf_id);
	while (1) 
	{
		gknown S2* active_buf_id  = & static_mem.active_buf_id;
		gknown U4* ordering_buf   = r_(static_mem.ordering_tbl)[active_buf_id[0]];
		gknown PrimitiveArena* pa = & static_mem.primitives;
		update(pa, ordering_buf);
		render();
		gp_display_frame(& static_mem.screen_buf, active_buf_id, ordering_buf, pa);
	};
	return 0;
}
