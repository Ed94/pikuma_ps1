#include "stdio.h"
#include <stdlib.h>
#include "assert.h"
#include "libgpu.h"
#include "libetc.h"

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
typedef def_struct(Tile) {
	U32         tag;
	RGB8        color;
	BYTE        code;
	Rect_S16    rect;
};

#define PrimitiveBuff_Len 2048
#define OrderingTbl_Len   16

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
	S16                     active_screen_buf;
};
global SMemory static_mem;
extern SMemory static_mem;

BYTE* prim__alloc(SSIZE type_width, ct_lit Str8 type_name) {
	gknown PrimitiveArena*  pa  = & static_mem.primitives;
	gknown BYTE*            buf = (BYTE*) static_mem.primitives.buf[static_mem.active_screen_buf];
	assert(pa->used + type_width < PrimitiveBuff_Len);
	BYTE* next = buf + pa->used;
	pa->used  += type_width;
	return next;
}
#define prim_alloc(type) (type*)prim__alloc(size_of(type), txt( stringify(type) ))

void gp_screen_init_c11(DoubleBuffer* screen_buf, S16* active_screen_buf)
{
	ResetGraph(0);
	SetDispMask(1); // gp_DisplayEnabled

	// Just setting env data, not interacting with console hw.
	// First buffer area
	SetDefDispEnv((DISPENV*)& screen_buf->display[0], 0, 0,           ScreenRes_X, ScreenRes_Y);
	SetDefDrawEnv((DRAWENV*)& screen_buf->draw   [0], 0, ScreenRes_Y, ScreenRes_X, ScreenRes_Y);
	// Second buffer area
	SetDefDispEnv((DISPENV*)& screen_buf->display[1], 0, ScreenRes_Y, ScreenRes_X, ScreenRes_Y);
	SetDefDrawEnv((DRAWENV*)& screen_buf->draw   [1], 0, 0,           ScreenRes_X, ScreenRes_Y);
	// Set the back/drawing buffer
	screen_buf->draw[0].enable_auto_clear = true;
	screen_buf->draw[1].enable_auto_clear = true;
	// Set the background clear color
	screen_buf->draw[0].initial_bg_color = (RGB8){ .r = 63,  .g = 0,  .b = 127 };
	screen_buf->draw[1].initial_bg_color = (RGB8){ .r = 127, .g = 63, .b = 0 };
	// Set the current initial buffer
	* active_screen_buf = 0;

	PutDispEnv((DISPENV*)& screen_buf->display[* active_screen_buf]);

	DRAWENV* env = (DRAWENV*)& screen_buf->draw[* active_screen_buf];
	PutDrawEnv(env);

	// Initialize and setup the GTE geometry offsets
	InitGeom();

	SetGeomOffset(ScreenRes_CenterX, ScreenRes_CenterY);
	SetGeomScreen(ScreenRes_CenterX);
}

void gp_display_frame(DoubleBuffer* screen_buf, S16* active_screen_buf, U32* ordering_buf) {
	DrawSync(0);
	VSync(0);
	PutDispEnv((DISPENV*)& screen_buf->display[* active_screen_buf]);
	PutDrawEnv((DRAWENV*)& screen_buf->draw   [* active_screen_buf]);
	{
		DrawOTag((u_long*) (ordering_buf + OrderingTbl_Len - 1));
	}
	* active_screen_buf = ! (* active_screen_buf); // Swap current buffer

	gknown static_mem.primitives.used = 0;
}

void render(void) {
}

void update(PrimitiveArena* pa, S16 active_screen_buff, U32* ordering_buf) {
	
	ClearOTagR((u_long*) ordering_buf, OrderingTbl_Len);

	Tile* tile  = prim_alloc(Tile); setTile((TILE*) tile);
	tile->rect  = (Rect_S16){ 82, 32, 64, 64 };
	tile->color = (RGB8){ 0, 255, 0};
	addPrim(ordering_buf, tile);

	TriFlat* tri = prim_alloc(TriFlat); setPolyF3(tri);
	tri->p0    = (Vec_2S16){ 64, 100};
	tri->p1    = (Vec_2S16){200, 150};
	tri->p2    = (Vec_2S16){ 50, 220};
	tri->color = (RGB8){ 255, 0, 255 };
	addPrim(ordering_buf, tri);
}

int main(void)
{
	static_mem.primitives.used = 0;
	gp_screen_init();
	// gp_screen_init_c11(& static_mem.screen_buf, & static_mem.active_screen_buf);
	while (1) 
	{
		gknown S16* active_screen = & static_mem.active_screen_buf;
		gknown U32* ordering_buf  = static_mem.ordering_tbl[* active_screen];
		update(& static_mem.primitives, * active_screen, ordering_buf);
		render();
		gp_display_frame(& static_mem.screen_buf, active_screen, ordering_buf);
	};
	return 0;
}
