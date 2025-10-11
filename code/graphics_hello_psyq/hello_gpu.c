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

#define PrimitiveBuff_Len 2048
#define OrderingTbl_Len   1024

typedef U4 OrderingTable_Buffer[OrderingTbl_Len];
typedef def_farray(OrderingTable_Buffer, 2);

typedef B1 PrimitiveBuffer[PrimitiveBuff_Len];
typedef def_farray(PrimitiveBuffer, 2);
typedef def_struct(PrimitiveArena) {
	A2_PrimitiveBuffer buf;
	U4                 used;
};

#define Cube_num_verts 8
#define Cube_num_faces 12
typedef def_farray(V3_S2, Cube_num_verts);
typedef def_farray(V3_S2, Cube_num_faces);

void cube128_init(A8_V3_S2* verts, A12_V3_S2* faces) {
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
	memory_copy(faces, & (A12_V3_S2) {
			{ 0, 3, 2 }, // top
			{ 0, 2, 1 }, // top
			{ 4, 0, 1 }, // front
			{ 4, 1, 5 }, // front
			{ 7, 4, 5 }, // bottom
			{ 7, 5, 6 }, // bottom
			{ 5, 1, 2 }, // right
			{ 5, 2, 6 }, // right
			{ 2, 3, 7 }, // back
			{ 2, 7, 6 }, // back
			{ 0, 4, 7 }, // left
			{ 0, 7, 3 }  // left
		},
		size_of(A12_V3_S2)
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

	A8_V3_S2  cube_verts;
	A12_V3_S2 cube_faces;
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

	m3s2_rotation   (& static_mem.rotation,    & static_mem.tform_world);
	m3s2_translation(& static_mem.tform_world, & static_mem.translation);
	m3s2_scale      (& static_mem.tform_world, & static_mem.scale);

	gte_matrix_set_rotation   (& static_mem.tform_world);
	gte_matrix_set_translation(& static_mem.tform_world);

#if 1
	S4 nclip = 0;
	S4 orderingtbl_z = 0;
	A2_S2 p;    //???
	S4 flag; //????

	for (U4 face_id = 0; face_id < Cube_num_faces; face_id += 1)
	{
		Poly_G3* tri = prim_alloc(Poly_G3); set_poly_g3(tri);
		tri->c0 = rgb8(255,   0, 255);
		tri->c1 = rgb8(255, 255,   0);
		tri->c2 = rgb8(  0, 255, 255);

		V3_S2* face = & static_mem.cube_faces[face_id];
		V3_S2* p0   = & static_mem.cube_verts[face->x];
		V3_S2* p1   = & static_mem.cube_verts[face->y];
		V3_S2* p2   = & static_mem.cube_verts[face->z];

		// orderingtbl_z = 0;
		// orderingtbl_z += rtp_v3s2(p0, & tri->p0, & p, & flag);
		// orderingtbl_z += rtp_v3s2(p1, & tri->p1, & p, & flag);
		// orderingtbl_z += rtp_v3s2(p2, & tri->p2, & p, & flag);
		// orderingtbl_z /= 3;

		nclip = rtp_avg_nclip_a3_v3s2(
			p0, p1, p2, 
			& tri->p0, & tri->p1, & tri->p2, 
			& p, & orderingtbl_z, & flag
		);
		if (nclip <= 0) {
			continue;
		}

		if ((orderingtbl_z > 0) && (orderingtbl_z < OrderingTbl_Len)) {
			orderingtbl_add_primitive(ordering_buf[orderingtbl_z], tri);
		}
	}

	static_mem.rotation.x +=  6;
	static_mem.rotation.y +=  8;
	static_mem.rotation.z += 12;
#endif

#if 0
	Tile* tile  = prim_alloc(Tile); set_tile(tile);
	tile->rect  = (Rect_S2){ 82, 32, 64, 64 };
	tile->color = (RGB8){ 0, 255, 0};
	orderingtbl_add_primitive(ordering_buf, tile);

	Poly_F3* tri = prim_alloc(Poly_F3); set_poly_f3(tri);
	tri->p0    = v2s2(64,  100);
	tri->p1    = v2s2(200, 150);
	tri->p2    = v2s2(50,  220);
	tri->color = rgb8(255, 0, 255);
	orderingtbl_add_primitive(ordering_buf, tri);

	Poly_G4* quad = prim_alloc(Poly_G4); set_poly_g4(quad);
	quad->p0 = v2s2(140, 50);
	quad->p1 = v2s2(200, 40);
	quad->p2 = v2s2(170, 120);
	quad->p3 = v2s2(220, 80);
	quad->c0 = rgb8(255, 0, 0);
	quad->c1 = rgb8(0, 255, 0);
	quad->c3 = rgb8(0, 0, 255);
	orderingtbl_add_primitive(ordering_buf, quad);
	
	Poly_F4* quadf = prim_alloc(Poly_F4); set_poly_f4(quadf);
	quadf->p0    = v2s2(140 + 15, 50  + 9);
	quadf->p1    = v2s2(200 + 15, 40  + 9);
	quadf->p2    = v2s2(170 + 15, 120 + 9);
	quadf->p3    = v2s2(220 + 15, 80  + 9);
	quadf->color = rgb8(22, 22, 22);
	orderingtbl_add_primitive(ordering_buf, quadf);
#endif
}

int main(void)
{
	static_mem.primitives.used = 0;
	cube128_init(& static_mem.cube_verts, & static_mem.cube_faces);
	static_mem.rotation    = v3s2(0, 0, 0);
	static_mem.translation = v3s4(0, 0, 900);
	static_mem.scale       = v3s4(m3s2_one, m3s2_one, m3s2_one);
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
