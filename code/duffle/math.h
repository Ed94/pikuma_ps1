#ifdef INTELLISENSE_DIRECTIVES
#	pragma once
#	include "dsl.h"
#endif

typedef def_farray(S16, 2);
typedef def_farray(S32, 2);
// typedef def_farray(F32, 2);

typedef def_struct(Extent_2S16) { S16 width; S16 height; };
typedef def_struct(Extent_2S32) { S32 width; S32 height; };
// typedef def_struct(Extent_2F32) { F32 width; F32 height; }
typedef def_struct(Vec_2S16)    { S16 x;     S16 y; };
typedef def_struct(Vec_2S32)    { S32 x;     S32 y; };
// typedef def_struct(Vec_2F32)    { F32 x;     F32 y; };
typedef def_struct(Range_2S16) { Vec_2S16 p0; Vec_2S16 p1; };
typedef def_struct(Range_2S32) { Vec_2S32 p0; Vec_2S32 p1; };
// typedef def_struct(Range_2F32) { Vec_2F32 p0; Vec_2F32 p1; };

typedef def_struct(Rect_S16) { S16 x; S16 y; S16 width; S16 height; };
typedef def_struct(Rect_S32) { S32 x; S32 y; S32 width; S32 height; };
