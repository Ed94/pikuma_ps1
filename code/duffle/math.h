#ifdef INTELLISENSE_DIRECTIVES
#	pragma once
#	include "dsl.h"
#endif

#define min(A, B)       (((A) < (B)) ? (A) : (B))
#define max(A, B)       (((A) > (B)) ? (A) : (B))
#define clamp_bot(X, B) max(X, B)

typedef def_farray(S2, 2);
typedef def_farray(S2, 3);
typedef def_farray(S4, 2);
typedef def_farray(S4, 3);
typedef S2 A3A3_S2[3][3];

typedef def_struct(Extent2_S2) { S2 width; S2 height; };
typedef def_struct(Extent2_S4) { S4 width; S4 height; };
typedef def_struct(V2_S2)      { S2 x; S2 y; };
typedef def_struct(V2_S4)      { S4 x; S4 y; };
typedef def_struct(V3_S2)      { S2 x; S2 y; S2 z; S2 pad; };
typedef def_struct(V3_S4)      { S4 x; S4 y; S4 z; S4 pad; };
typedef def_struct(R2_S2)      { V2_S2 p0; V2_S2 p1; };
typedef def_struct(R2_S4)      { V2_S4 p0; V2_S4 p1; };

typedef def_struct(Rect_S2) { S2 x; S2 y; S2 width; S2 height; };
typedef def_struct(Rect_S4) { S4 x; S4 y; S4 width; S4 height; };

typedef def_struct(M3_S2) { A3A3_S2 m; A3_S4 t; };

#define v2_s2(x, y) (V2_S2){ x, y }
