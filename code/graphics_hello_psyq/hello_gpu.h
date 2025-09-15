#ifdef INTELLISENSE_DIRECTIVES
#	pragma once
#	include "duffle/dsl.h"
#	include "duffle/math.h"
#	include "duffle/gp.h"
#endif

typedef def_struct(DrawEnv_Packed) { U32 tag; U32 code[15]; };
typedef def_struct(DrawEnv) {
	Rect_S16 clip_area;
	A2_S16   drawing_offset;
	Rect_S16 texture_window;
	S16      texture_page;
	BYTE     flag_dither;	
	BYTE     flag_draw_on_display;
	BYTE     enable_auto_clear;
	RGB8     initial_bg_color;
	DrawEnv_Packed dr_env; // reserved
};
typedef def_struct(DisplayEnv) {
	Rect_S16 display_area;
	Rect_S16 screen;
	BYTE     vinterlace;
	BYTE     color24;
	BYTE     pad0;
	BYTE     pad1;
};
typedef def_farray(DrawEnv,    2);
typedef def_farray(DisplayEnv, 2);
typedef def_struct(DoubleBuffer) {
	A2_DrawEnv    draw;
	A2_DisplayEnv display;
};

#define ScreenRes_X 320
#define ScreenRes_Y 240
#define ScreenZ     400
#define ScreenRes_CenterX (ScreenRes_X >> 1)
#define ScreenRes_CenterY (ScreenRes_Y >> 1)


DisplayEnv* displayenv_init(DisplayEnv* env, S32 x, S32 y, S32 w, S32 h) __asm__("SetDefDispEnv");
DrawEnv*    drawenv_init   (DrawEnv*    env, S32 x, S32 y, S32 w, S32 h) __asm__("SetDefDrawEnv");

DisplayEnv* displayenv_put(DisplayEnv* env) __asm__("PutDispEnv");
DrawEnv*    drawenv_put   (DrawEnv*    env) __asm__("PutDrawEnv");

U32  geom_init(void)               __asm__("InitGeom");
void geom_set_offset(U32 x, U32 y) __asm__("SetGeomOffset");
void geom_set_screen(U32 h)        __asm__("SetGeomScreen");

U32* orderingtbl_clear_reverse(U32* ot, SSIZE len) __asm__("ClearOTagR");

U32 reset_graph(U32 mode)          __asm__("ResetGraph");
void set_display_enabled(U32 mask) __asm__("SetDispMask");

U32 draw_sync(U32 mode) __asm__("DrawSync");
U32 vsync(U32 mode) __asm("VSync");

void draw_orderingtbl(U32* buf) __asm__("DrawOTag");

typedef def_struct(PolyTag) {
	U32  addr: 24;
	U32  len:  8;
	RGB8 color;
	BYTE code;
};

/*
 * Primitive Handling Macros
 */
#define set_len( p, _len) 	(((PolyTag*)(p))->len  = (BYTE)(_len))
#define set_addr(p, _addr)	(((PolyTag*)(p))->addr = (U32 )(_addr))
#define set_code(p, _code)	(((PolyTag*)(p))->code = (BYTE)(_code))

#define get_len(p)    		(BYTE)(((PolyTag*)(p))->len)
#define get_code(p)   		(BYTE)(((PolyTag*)(p))->code)
#define get_addr(p)   		(U32 )(((PolyTag*)(p))->addr)

#define orderingtbl_add_primitive(ot, p)		    set_addr(p,  get_addr(ot)), set_addr(ot, p)
#define orderingtbl_add_primitives(ot, p0, p1)	set_addr(p1, get_addr(ot)), set_addr(ot, p0)

/*	Primitive 	Lentgh		Code				*/
/*--------------------------------------------------------------------	*/
/*									*/
#define set_tri_flat(p)	    set_len(p, 4),  set_code(p, 0x20)
// #define setPolyFT3(p)	      set_len(p, 7),  set_code(p, 0x24)
// #define setPolyG3(p)	      set_len(p, 6),  set_code(p, 0x30)
// #define setPolyGT3(p)	      set_len(p, 9),  set_code(p, 0x34)
#define set_quad_flat(p)	  set_len(p, 5),  set_code(p, 0x28)
// #define setPolyFT4(p)	      set_len(p, 9),  set_code(p, 0x2c)
#define set_quad_gouraud(p)	set_len(p, 8),  set_code(p, 0x38)
// #define setPolyGT4(p)	      set_len(p, 12), set_code(p, 0x3c)

// #define setSprt8(p)	setlen(p, 3),  setcode(p, 0x74)
// #define setSprt16(p)	setlen(p, 3),  setcode(p, 0x7c)
// #define setSprt(p)	setlen(p, 4),  setcode(p, 0x64)

// #define setTile1(p) 	set_len(p, 2),  set_code(p, 0x68)
// #define setTile8(p) 	set_len(p, 2),  set_code(p, 0x70)
// #define setTile16(p)	set_len(p, 2),  set_code(p, 0x78)
#define set_tile(p) 	set_len(p, 3),  set_code(p, 0x60)
// #define setLineF2(p)	set_len(p, 3),  set_code(p, 0x40)
// #define setLineG2(p)	set_len(p, 4),  set_code(p, 0x50)
// #define setLineF3(p)	set_len(p, 5),  set_code(p, 0x48),(p)->pad = 0x55555555
// #define setLineG3(p)	set_len(p, 7),  set_code(p, 0x58),(p)->pad = 0x55555555, (p)->p2 = 0
// #define setLineF4(p)	set_len(p, 6),  set_code(p, 0x4c),(p)->pad = 0x55555555
// #define setLineG4(p)	set_len(p, 9),  set_code(p, 0x5c),(p)->pad = 0x55555555, (p)->p2 = 0, (p)->p3 = 0
