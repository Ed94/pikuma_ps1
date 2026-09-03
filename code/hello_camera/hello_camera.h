#ifdef INTELLISENSE_DIRECTIVES
#	pragma once
#	include "duffle/dsl.h"
#	include "duffle/math.h"
#	include "duffle/gp.h"
#	include "duffle/pad.h"
#endif

enum {
	// PrimitiveBuff_Len = 4096,
	// OrderingTbl_Len   = 2048,
	PrimitiveBuff_Len = 131072,
	OrderingTbl_Len   = 8192,
};

enum {
	ScreenRes_X = 320,
	ScreenRes_Y = 240,
	ScreenZ     = 320,
	ScreenRes_CenterX = (ScreenRes_X >> 1),
	ScreenRes_CenterY = (ScreenRes_Y >> 1),
};

typedef U4 OrderingTable_Buffer[OrderingTbl_Len];
typedef Array_(OrderingTable_Buffer, 2);

typedef U1 PrimitiveBuffer[PrimitiveBuff_Len];
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
	mem_copy(b1_r(verts), b1_r(& baked_verts), S_(A8_V3_S2) );
	mem_copy(b1_r(faces), b1_r(& baked_faces), S_(A6_V4_S2) );
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
	mem_copy(b1_r(verts), b1_r(& baked_verts), S_(A4_V3_S2));
	mem_copy(b1_r(faces), b1_r(& baked_faces), S_(A2_V3_S2));
};
typedef Struct_(Ent_Floor) {
	V3_S4 accel;
	V3_S4 pos;
	V3_S4 scale;
	V3_S2 rot;
	A4_V3_S2 verts;
	A2_V3_S2 faces;
};

typedef Struct_(Camera) {
	P3_S4    pos;
	V3_S2    rot;
	MT3_S2S4 look_at;
};
