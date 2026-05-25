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

typedef def_farray(V2_S2, 3);
typedef def_struct(Poly_F3) {
	U4   tag;
	RGB8 color;
	B1   code;
	union {
		struct {
			V2_S2 p0;
			V2_S2 p1;
			V2_S2 p2;
		};
		A3_V2_S2 points;
	};
};
typedef def_struct(Poly_G3) {
	U4    tag; RGB8 c0; B1 code;
	V2_S2 p0;  RGB8 c1; B1 pad1;
	V2_S2 p1;  RGB8 c2; B1 pad2;
	V2_S2 p2;
};
typedef def_farray(V2_S2, 4);
typedef def_struct(Poly_F4) {
	U4   tag;
	RGB8 color;
	B1   code;
	union {
		struct {
			V2_S2 p0;
			V2_S2 p1;
			V2_S2 p2;
			V2_S2 p3;
		};
		A4_V2_S2 points;
	};
};
typedef def_struct(Poly_G4) {
	U4    tag; RGB8 c0; B1 code;
	V2_S2 p0;  RGB8 c1; B1 pad1;
	V2_S2 p1;  RGB8 c2; B1 pad2;
	V2_S2 p2;  RGB8 c3; B1 pad3;
	V2_S2 p3;
};
typedef def_struct(Tile) {
	U4      tag;
	RGB8    color;
	B1      code;
	Rect_S2 rect;
};

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
typedef A6_V4_S2 ACubeFaces;
void cube128_init(A8_V3_S2* verts, ACubeFaces* faces) {
	memory_copy(verts, & (A8_V3_S2) {
			{ -128, -128, -128 },
			{  128, -128, -128 },
			{  128, -128,  128 },
			{ -128, -128,  128 },
			{ -128,  128, -128 },
			{  128,  128, -128 },
			{  128,  128,  128 },
			{ -128,  128,  128 }
		},
		size_of(A8_V3_S2)
	);
	memory_copy(faces, & (A6_V4_S2) {
			{ 3, 2, 0, 1 },
			{ 0, 1, 4, 5 },
			{ 4, 5, 7, 6 },
			{ 1, 2, 5, 6 },
			{ 2, 3, 6, 7 },
			{ 3, 0, 7, 4 },
		},
		sizeof(A6_V4_S2)
	);
	return;
}

typedef def_struct(SMemory) {
	DoubleBuffer            screen_buf;
	A2_OrderingTable_Buffer ordering_tbl;
	PrimitiveArena          primitives;
	S2                      active_buf_id;

	V3_S2 rotation;
	V3_S4 translation;
	V3_S4 scale;

	M3_S2 tform_world;

	A8_V3_S2   cube_verts;
	ACubeFaces cube_faces;

	V3_S4 vel;
	V3_S4 acc;
	V3_S4 pos;
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
	screen_buf->draw[0].initial_bg_color = rgb8( .r = 13, .g = 0,  .b = 47 );
	screen_buf->draw[1].initial_bg_color = rgb8( .r = 47, .g = 13, .b = 0 );
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
	gknown V3_S4_R pos = & static_mem.pos;
	gknown V3_S4_R vel = & static_mem.vel;
	gknown V3_S4_R acc = & static_mem.acc;
	add_v3s4(vel, acc[0]);
	add_v3s4(pos, vel[0]);
	// vel->x += acc->x;
	// vel->y += acc->y;
	// vel->z += acc->z;
	// pos->x += vel->x;
	// pos->y += vel->y;
	// pos->z += vel->z;

	if (pos->y > 400) vel->y *= -1;

	m3s2_rotation   (& static_mem.rotation,    & static_mem.tform_world);
	m3s2_translation(& static_mem.tform_world, & static_mem.pos);
	m3s2_scale      (& static_mem.tform_world, & static_mem.scale);

	gte_matrix_set_rotation   (& static_mem.tform_world);
	gte_matrix_set_translation(& static_mem.tform_world);

	S4 nclip = 0;
	S4 orderingtbl_z = 0;
	A2_S2 p;    //???
	S4 flag; //????

	for (U4 face_id = 0; face_id < Cube_num_faces; face_id += 1)
	{
		Poly_G4* quad = prim_alloc(Poly_G4); set_poly_g4(quad);
		quad->c0 = rgb8(255,   0, 255);
		quad->c1 = rgb8(255, 255,   0);
		quad->c2 = rgb8(  0, 255, 255);
		quad->c3 = rgb8(  0, 255,   0);

		V4_S2* face = & static_mem.cube_faces[face_id];
		V3_S2* p0   = & static_mem.cube_verts[face->x];
		V3_S2* p1   = & static_mem.cube_verts[face->y];
		V3_S2* p2   = & static_mem.cube_verts[face->z];
		V3_S2* p3   = & static_mem.cube_verts[face->w];

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
	// static_mem.rotation.x +=  6;
	// static_mem.rotation.y +=  8;
	// static_mem.rotation.z += 12;
	static_mem.rotation.x += 20;
}

int main(void)
{
	static_mem = (SMemory){0};
	static_mem.primitives.used = 0;
	cube128_init(& static_mem.cube_verts, & static_mem.cube_faces);
	static_mem.rotation    = v3s2(0, 0, 0);
	static_mem.translation = v3s4(0, 0, 900);
	static_mem.scale       = v3s4(fp_one, fp_one, fp_one);
	static_mem.acc = v3s4(0, 1, 0);
	static_mem.pos = v3s4(0, -400, 1800);
	gknown gp_screen_init();
	// gp_screen_init_c11(& static_mem.screen_buf, & static_mem.active_screen_buf);
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
