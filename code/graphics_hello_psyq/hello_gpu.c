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

typedef def_farray(Vec_2S16, 3);
typedef def_struct(TriFlat) {
	U32  tag;
	RGB8 color;
	BYTE code;
	union {
		struct {
			Vec_2S16 p0;
			Vec_2S16 p1;
			Vec_2S16 p2;
		};
		A3_Vec_2S16 points;
	};
};
typedef def_farray(Vec_2S16, 4);
typedef def_struct(QuadFlat) {
	U32  tag;
	RGB8 color;
	BYTE code;
	union {
		struct {
			Vec_2S16 p0;
			Vec_2S16 p1;
			Vec_2S16 p2;
			Vec_2S16 p3;
		};
		A4_Vec_2S16 points;
	};
};
typedef def_struct(QuadGouraud) {
	U32      tag; RGB8 c0; BYTE code;
	Vec_2S16 p0;  RGB8 c1; BYTE pad1;
	Vec_2S16 p1;  RGB8 c2; BYTE pad2;
	Vec_2S16 p2;  RGB8 c3; BYTE pad3;
	Vec_2S16 p3;
};
typedef def_struct(Tile) {
	U32      tag;
	RGB8     color;
	BYTE     code;
	Rect_S16 rect;
};

#define PrimitiveBuff_Len 2048
#define OrderingTbl_Len   32

typedef U32 OrderingTable_Buffer[OrderingTbl_Len];
typedef def_farray(OrderingTable_Buffer, 2);

typedef BYTE PrimitiveBuffer[PrimitiveBuff_Len];
typedef def_farray(PrimitiveBuffer, 2);
typedef def_struct(PrimitiveArena) {
	A2_PrimitiveBuffer buf;
	SSIZE              used;
};

typedef def_struct(SMemory) {
	DoubleBuffer            screen_buf;
	A2_OrderingTable_Buffer ordering_tbl;
	PrimitiveArena          primitives;
	S16                     active_buf_id;
};
global SMemory static_mem;
extern SMemory static_mem;

BYTE* prim__alloc(SSIZE type_width, dbg_args(Str8 type_name)) {
	gknown PrimitiveArena*  pa  = & static_mem.primitives;
	gknown BYTE*            buf = (BYTE*) static_mem.primitives.buf[static_mem.active_buf_id];
	assert(pa->used + type_width < PrimitiveBuff_Len);
	BYTE* next = buf + pa->used;
	pa->used  += type_width;
	return next;
}
#define prim_alloc(type) (type*)prim__alloc(size_of(type), txt( stringify(type)))

void gp_screen_init_c11(DoubleBuffer* screen_buf, S16* active_buf_id)
{
	reset_graph(0);
	set_display_enabled(1); // gp_DisplayEnabled

	// Set the current initial buffer
	* active_buf_id = 0;

	// Just setting env data, not interacting with console hw.
	// First buffer area
	displayenv_init(& screen_buf->display[0], 0, 0,           ScreenRes_X, ScreenRes_Y);
	drawenv_init   (& screen_buf->draw   [0], 0, ScreenRes_Y, ScreenRes_X, ScreenRes_Y);
	// Second buffer area
	displayenv_init(& screen_buf->display[1], 0, ScreenRes_Y, ScreenRes_X, ScreenRes_Y);
	drawenv_init   (& screen_buf->draw   [1], 0, 0,           ScreenRes_X, ScreenRes_Y);
	// Set the back/drawing buffer
	screen_buf->draw[0].enable_auto_clear = true;
	screen_buf->draw[1].enable_auto_clear = true;
	// Set the background clear color
	screen_buf->draw[0].initial_bg_color = rgba8( .r = 63,  .g = 0,  .b = 127 );
	screen_buf->draw[1].initial_bg_color = rgba8( .r = 127, .g = 63, .b = 0 );
	displayenv_put(& screen_buf->display[* active_buf_id]);
	drawenv_put   (& screen_buf->draw   [* active_buf_id]);

	// Initialize and setup the GTE geometry offsets
	geom_init();
	geom_set_offset(ScreenRes_CenterX, ScreenRes_CenterY);
	geom_set_screen(ScreenZ);
}

void gp_display_frame(DoubleBuffer* screen_buf, S16* active_buf_id, U32* ordering_buf, PrimitiveArena* pa) {
	draw_sync(0);
	vsync(0);
	displayenv_put(& screen_buf->display[* active_buf_id]);
	drawenv_put   (& screen_buf->draw   [* active_buf_id]);
	{
		draw_orderingtbl(ordering_buf + OrderingTbl_Len - 1);
		pa->used = 0;
	}
	* active_buf_id = ! (* active_buf_id); // Swap current buffer
}

void render(void) {
}

void update(PrimitiveArena* pa, U32* ordering_buf) {
	
	orderingtbl_clear_reverse(ordering_buf, OrderingTbl_Len);

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
}

int main(void)
{
	static_mem.primitives.used = 0;
	gknown gp_screen_init();
	// gp_screen_init_c11(& static_mem.screen_buf, & static_mem.active_screen_buf);
	while (1) 
	{
		gknown S16* active_buf_id = & static_mem.active_buf_id;
		gknown U32* ordering_buf  = static_mem.ordering_tbl[* active_buf_id];
		gknown PrimitiveArena* pa = & static_mem.primitives;
		update(pa, ordering_buf);
		render();
		gp_display_frame(& static_mem.screen_buf, active_buf_id, ordering_buf, pa);
	};
	return 0;
}
