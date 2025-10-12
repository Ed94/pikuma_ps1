#ifdef INTELLISENSE_DIRECTIVES
#	pragma once
#	include "duffle/dsl.h"
#	include "duffle/math.h"
#	include "duffle/gp.h"
#endif

typedef def_struct(DrawEnv_Packed) { U4 tag; U4 code[15]; };
typedef def_struct(DrawEnv) {
	Rect_S2 clip_area;
	A2_S2   drawing_offset;
	Rect_S2 texture_window;
	S2      texture_page;
	B1      flag_dither;	
	B1      flag_draw_on_display;
	B1      enable_auto_clear;
	RGB8    initial_bg_color;
	DrawEnv_Packed dr_env; // reserved
};
typedef def_struct(DisplayEnv) {
	Rect_S2 display_area;
	Rect_S2 screen;
	B1      vinterlace;
	B1      color24;
	B1      pad0;
	B1      pad1;
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

DisplayEnv* displayenv_init(DisplayEnv* env, S4 x, S4 y, S4 w, S4 h) __asm__("SetDefDispEnv");
DrawEnv*    drawenv_init   (DrawEnv*    env, S4 x, S4 y, S4 w, S4 h) __asm__("SetDefDrawEnv");

DisplayEnv* displayenv_put(DisplayEnv* env) __asm__("PutDispEnv");
DrawEnv*    drawenv_put   (DrawEnv*    env) __asm__("PutDrawEnv");

U4   geom_init(void)             __asm__("InitGeom");
void geom_set_offset(U4 x, U4 y) __asm__("SetGeomOffset");
void geom_set_screen(U4 h)       __asm__("SetGeomScreen");

U4* orderingtbl_clear_reverse(U4* ot, U4 len) __asm__("ClearOTagR");

U4 reset_graph(U4 mode)          __asm__("ResetGraph");
void set_display_enabled(U4 mask) __asm__("SetDispMask");

U4 draw_sync(U4 mode) __asm__("DrawSync");
U4 vsync(U4 mode)     __asm__("VSync");

void draw_orderingtbl(U4* buf) __asm__("DrawOTag");

typedef def_struct(PolyTag) {
	U4   addr: 24;
	U4   len:  8;
	RGB8 color;
	B1   code;
};

/*
 * Primitive Handling Macros
 */

#define set_len( p, _len) 	(((PolyTag*R_)(p))->len  = (B1)(_len))
#define set_addr(p, _addr)	(((PolyTag*R_)(p))->addr = (U4)(_addr))
#define set_code(p, _code)	(((PolyTag*R_)(p))->code = (B1)(_code))

#define get_len(p)    	    (B1)(((PolyTag*R_)(p))->len)
#define get_code(p)   	    (B1)(((PolyTag*R_)(p))->code)
#define get_addr(p)   	    (U4)(((PolyTag*R_)(p))->addr)

#define orderingtbl_add_primitive(ot, p)		    set_addr(p,  get_addr(ot)), set_addr(ot, p)
#define orderingtbl_add_primitives(ot, p0, p1)	set_addr(p1, get_addr(ot)), set_addr(ot, p0)

/* Primitive 	Length		Code */

#define set_poly_f3(p)	set_len(p, 4),  set_code(p, 0x20)
#define set_poly_ft3(p)	set_len(p, 7),  set_code(p, 0x24)
#define set_poly_g3(p)  set_len(p, 6),  set_code(p, 0x30)
#define set_poly_gt3(p)	set_len(p, 9),  set_code(p, 0x34)
#define set_poly_f4(p)	set_len(p, 5),  set_code(p, 0x28)
#define set_poly_ft4(p)	set_len(p, 9),  set_code(p, 0x2c)
#define set_poly_g4(p)  set_len(p, 8),  set_code(p, 0x38)
#define set_poly_gt4(p)	set_len(p, 12), set_code(p, 0x3c)

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

/*
	Linear Algebra
*/

M3_S2* m3s2_rotation   (V3_S2* vec, M3_S2* mat) __asm__("RotMatrix");
M3_S2* m3s2_translation(M3_S2* mat, V3_S4* vec) __asm__("TransMatrix");
M3_S2* m3s2_scale      (M3_S2* mat, V3_S4* vec) __asm__("ScaleMatrix");

// Rotation, Translation, Perspective

S4 rtp_v3s2_raw(V3_S2* vec, S4* xy, S4* pp, S4* flag) __asm__("RotTransPers");
finline S4 rtp_v3s2(V3_S2* vec, V2_S2* xy, A2_S2* pp, S4* flag) { return rtp_v3s2_raw(vec, cast(S4*R_, & xy->x), cast(S4*R_, pp), r_(flag)); }

S4 rtp_avg_nclip_a3_v3s2_raw(V3_S2* v0, V3_S2* v1, V3_S2* v2, S4* xy1, S4* xy2, S4* xy3, S4* pp, S4* otz, S4* flag) __asm__("RotAverageNclip3");
finline  S4 rtp_avg_nclip_a3_v3s2(
	V3_S2* v0,  V3_S2* v1,  V3_S2* v2, 
	V2_S2* xy0, V2_S2* xy1, V2_S2* xy2, 
	A2_S2* pp, S4* otz, S4* flag
){
	return rtp_avg_nclip_a3_v3s2_raw(
		v0, v1, v2, 
		cast(S4*R_, xy0), cast(S4*R_, xy1), cast(S4*R_, xy2),
		cast(S4*R_, pp),  cast(S4*R_, otz), cast(S4*R_, flag)
	);
}

void gte_matrix_set_rotation   (M3_S2* mat) __asm__("SetRotMatrix");
void gte_matrix_set_translation(M3_S2* mat) __asm__("SetTransMatrix");

#define fp_one (1 << 12)
