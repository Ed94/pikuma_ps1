#ifdef INTELLISENSE_DIRECTIVES
#	pragma once
#	include "dsl.h"
#	include "math.h"
#	include "gp.h"
#endif

typedef Struct_(DrawEnv_Packed) { U4 tag; U4 code[15]; };
typedef Struct_(DrawEnv) {
	Rect_S2 clip_area;
	V2_S2   drawing_offset[2];
	Rect_S2 texture_window;
	S2      texture_page;
	B1      flag_dither;
	B1      flag_draw_on_display;
	B1      enable_auto_clear;
	RGB8    initial_bg_color;
	DrawEnv_Packed dr_env; // reserved
};
typedef Struct_(DisplayEnv) {
	Rect_S2 display_area;
	Rect_S2 screen;
	B1      vinterlace;
	B1      color24;
	B1      pad0;
	B1      pad1;
};
typedef Array_(DrawEnv,    2);
typedef Array_(DisplayEnv, 2);

typedef Struct_(DoubleBuffer) {
	A2_DrawEnv    draw;
	A2_DisplayEnv display;
};

DisplayEnv* displayenv_init(DisplayEnv* env, S4 x, S4 y, S4 w, S4 h) asm("SetDefDispEnv");
DrawEnv*    drawenv_init   (DrawEnv*    env, S4 x, S4 y, S4 w, S4 h) asm("SetDefDrawEnv");

DisplayEnv* displayenv_put(DisplayEnv* env) asm("PutDispEnv");
DrawEnv*    drawenv_put   (DrawEnv*    env) asm("PutDrawEnv");

U4   geom_init(void)             asm("InitGeom");
void geom_set_offset(U4 x, U4 y) asm("SetGeomOffset");
void geom_set_screen(U4 h)       asm("SetGeomScreen");

U4* orderingtbl_clear_reverse(U4* ot, U4 len) asm("ClearOTagR");

U4 reset_graph(U4 mode)           asm("ResetGraph");
void set_display_enabled(U4 mask) asm("SetDispMask");

U4 draw_sync(U4 mode) asm("DrawSync");
U4 vsync(U4 mode)     asm("VSync");

void draw_orderingtbl(U4* buf) asm("DrawOTag");

typedef Struct_(Tile) {
	U4      tag;
	RGB8    color;
	B1      code;
	Rect_S2 rect;
};

/*
	Linear Algebra
*/

MT3_S2S4* mt3s2s4_rotation   (V3_S2*    vec, MT3_S2S4* mat) asm("RotMatrix");
MT3_S2S4* mt3s2s4_translation(MT3_S2S4* mat, V3_S4*    vec) asm("TransMatrix");
MT3_S2S4* mt3s2s4_scale      (MT3_S2S4* mat, V3_S4*    vec) asm("ScaleMatrix");

// Rotation, Translation, Perspective

S4 rtp_v3s2_raw(V3_S2* vec, S4* xy, S4* pp, S4* flag) asm("RotTransPers");
FI_ S4 rtp_v3s2(V3_S2* vec, V2_S2* xy, A2_S2* pp, S4* flag) { return rtp_v3s2_raw(vec, C_(S4*R_, & xy->x), C_(S4*R_, pp), r_(flag)); }

S4 rtp_avg_nclip_a3_v3s2_raw(V3_S2* v0, V3_S2* v1, V3_S2* v2, S4* xy1, S4* xy2, S4* xy3, S4* pp, S4* otz, S4* flag) asm("RotAverageNclip3");
FI_  S4 rtp_avg_nclip_a3_v3s2(
	V3_S2* v0,  V3_S2* v1,  V3_S2* v2, 
	V2_S2* xy0, V2_S2* xy1, V2_S2* xy2, 
	A2_S2* pp, S4* otz, S4* flag
){
	return rtp_avg_nclip_a3_v3s2_raw(
		v0, v1, v2, 
		C_(S4*R_, xy0), C_(S4*R_, xy1), C_(S4*R_, xy2),
		C_(S4*R_, pp),  C_(S4*R_, otz), C_(S4*R_, flag)
	);
}

S4 rtp_avg_nclip_a4_v3s2_raw(V3_S2* v0, V3_S2* v1, V3_S2* v2, V3_S2* v3, S4* xy1, S4* xy2, S4* xy3, S4* xy4, S4* pp, S4* otz, S4* flag) asm("RotAverageNclip4");
FI_ S4 rtp_avg_nclip_a4_v3s2(
	V3_S2* v0,  V3_S2* v1,  V3_S2* v2,  V3_S2* v3,
	V2_S2* xy0, V2_S2* xy1, V2_S2* xy2, V2_S2* xy3,
	A2_S2* pp,  S4* otz,    S4* flag
){
	return rtp_avg_nclip_a4_v3s2_raw(
		v0, v1, v2, v3,
		C_(S4*R_, xy0), C_(S4*R_, xy1), C_(S4*R_, xy2), C_(S4*R_, xy3),
		C_(S4*R_, pp),  C_(S4*R_, otz), C_(S4*R_, flag)
	);
}

void gte_matrix_set_rotation   (MT3_S2S4* mat) asm("SetRotMatrix");
void gte_matrix_set_translation(MT3_S2S4* mat) asm("SetTransMatrix");

// Einheit, Metrication to unit vector. "Normalization", not Orthogonal "Normal, Normalis". Directionalization.
// RGA(Lengyel): Normalize the bulk of a zero-weight direction. This is not finite-point unitization (which forces w=1).
S4 normalize_v3s4(V3_S4* v0, V3_S4* v1) asm("VectorNormal");

// RGA(Lengyel): Apply the matrix expansion of a rigid transformation.
// Motor antiproduct is equivalent for unitized points; LA form is what GTE consumes.
V3_S4* mul_m3s2_v3s4(MT3_S2S4* m, V3_S4* v, V3_S4* result) asm("ApplyMatrixLV");

// RGA(Lengyel): Store the full translation column. The motor translator would store half this displacement in m.xyz.
MT3_S2S4* trans_m3s2(MT3_S2S4* m, V3_S4* off) asm("TransMatrix");

MT3_S2S4* gte_comp_coord_m3s2(MT3_S2S4* m0, MT3_S2S4* m1, MT3_S2S4* result) asm("CompMatrixLV");

// RGA(Lengyel): Complement(Wedge(a,b)), i.e. the Euclidean 3D complement of the exterior product, stored as a V3_S4.
// The underlying GTE OP is a specialized signed-16-bit D x IR command; the wedge interpretation is a 3D dual of the same 3 scalars.
void cross_v3s4(V3_S4* v0, V3_S4* v1, V3_S4* result) asm("OuterProduct12");

