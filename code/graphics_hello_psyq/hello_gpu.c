#include "stdio.h"
#include <stdlib.h>
#include "assert.h"
// #include "libgpu.h"
// #include "libetc.h"

#include "duffle/dsl.h"
#include "duffle/memory.h"
#include "duffle/math.h"
#include "duffle/gp.h"
#include "hello_gpu.h"

typedef def_farray(V2_S2, 3);
typedef def_struct(TriFlat) {
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
typedef def_farray(V2_S2, 4);
typedef def_struct(QuadFlat) {
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
typedef def_struct(QuadGouraud) {
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
#define OrderingTbl_Len   256

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
	set_display_enabled(1); // gp_DisplayEnabled

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
	screen_buf->draw[0].initial_bg_color = rgba8( .r = 63,  .g = 0,  .b = 127 );
	screen_buf->draw[1].initial_bg_color = rgba8( .r = 127, .g = 63, .b = 0 );
	displayenv_put(& r_(screen_buf->display)[ active_buf_id[0] ]);
	drawenv_put   (& r_(screen_buf->draw   )[ active_buf_id[0] ]);

	// Initialize and setup the GTE geometry offsets
	geom_init();
	geom_set_offset(ScreenRes_CenterX, ScreenRes_CenterY);
	geom_set_screen(ScreenZ);
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
	* active_buf_id = ! (* active_buf_id); // Swap current buffer
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

	TriFlat* tri = prim_alloc(TriFlat); set_tri_flat(tri);
	tri->color = rgba8(255, 0, 0);

	S4 otz = 0;
	// otz += vec_3s16_rtp(& )

#if 0
	Tile* tile  = prim_alloc(Tile); set_tile(tile);
	tile->rect  = (Rect_S16){ 82, 32, 64, 64 };
	tile->color = (RGB8){ 0, 255, 0};
	orderingtbl_add_primitive(ordering_buf, tile);

	TriFlat* tri = prim_alloc(TriFlat); set_tri_flat(tri);
	tri->p0    = vec_2s16(64,  100);
	tri->p1    = vec_2s16(200, 150);
	tri->p2    = vec_2s16(50,  220);
	tri->color = rgba8(255, 0, 255);
	orderingtbl_add_primitive(ordering_buf, tri);

	QuadGouraud* quad = prim_alloc(QuadGouraud); set_quad_gouraud(quad);
	quad->p0 = vec_2s16(140, 50);
	quad->p1 = vec_2s16(200, 40);
	quad->p2 = vec_2s16(170, 120);
	quad->p3 = vec_2s16(220, 80);
	quad->c0 = rgba8(255, 0, 0);
	quad->c1 = rgba8(0, 255, 0);
	quad->c3 = rgba8(0, 0, 255);
	orderingtbl_add_primitive(ordering_buf, quad);
	
	QuadFlat* quadf = prim_alloc(QuadFlat); set_quad_flat(quadf);
	quadf->p0 = vec_2s16(140 + 15, 50  + 9);
	quadf->p1 = vec_2s16(200 + 15, 40  + 9);
	quadf->p2 = vec_2s16(170 + 15, 120 + 9);
	quadf->p3 = vec_2s16(220 + 15, 80  + 9);
	quadf->color = rgba8(22, 22, 22);
	orderingtbl_add_primitive(ordering_buf, quadf);
#endif
}

int main(void)
{
	static_mem.primitives.used = 0;
	cube128_init(& static_mem.cube_verts, & static_mem.cube_faces);
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
