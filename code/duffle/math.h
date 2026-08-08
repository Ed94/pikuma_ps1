#ifdef INTELLISENSE_DIRECTIVES
#	pragma once
#	include "dsl.h"
#endif

#define min(A, B)       (((A) < (B)) ? (A) : (B))
#define max(A, B)       (((A) > (B)) ? (A) : (B))
#define clamp_bot(X, B) max(X, B)

enum { 
	v3s2_byteoff = 3, // log2(8), used with shift_left_logical op for index via byte offset.
};

typedef Array_(U1, 2);
typedef Array_(U4, 2);
typedef Array_(S2, 2);
typedef Array_(S2, 3);
typedef Array_(S4, 2);
typedef Array_(S4, 3);
typedef Array_(S4, 4);
typedef S2 A3x3_S2[3][3];

typedef Struct_(Extent2_S2) { S2 width; S2 height; };
typedef Struct_(Extent2_S4) { S4 width; S4 height; };

typedef Struct_(V2_U1)      { U1 x; U1 y; };
typedef Struct_(V2_S2)      { S2 x; S2 y; };
typedef Struct_(V2_S4)      { S4 x; S4 y; };
typedef Struct_(V3_S2)      { S2 x; S2 y; S2 z; S2 pad; };
typedef Struct_(V3_S4)      { S4 x; S4 y; S4 z; S4 pad; };
typedef Struct_(V4_S2)      { S2 x; S2 y; S2 z; S2 w; };
typedef Struct_(V4_S4)      { S4 x; S4 y; S4 z; S4 w; };

typedef Struct_(R2_S2)      { V2_S2 p0; V2_S2 p1; };
typedef Struct_(R2_S4)      { V2_S4 p0; V2_S4 p1; };

typedef Struct_(Rect_S2)    { S2 x; S2 y; S2 width; S2 height; };
typedef Struct_(Rect_S4)    { S4 x; S4 y; S4 width; S4 height; };

typedef Struct_(M3_S2)      { A3x3_S2 m; A3_S4 t; };

typedef Array_(V2_U1, 2);
typedef Array_(V2_S2, 2);
typedef Array_(V2_S2, 3);
typedef Array_(V2_S2, 4);

#define v2s2(x,y)     (V2_S2){x,y}
#define v3s2(x,y,z)   (V3_S2){x,y,z,0}
#define v3s4(x,y,z)   (V3_S4){x,y,z,0}
#define v4s2(x,y,z,w) (V4_S2){x,y,z,w}
#define v4s4(x,y,z,w) (V4_S4){x,y,z,w}

FI_ void add_a3s4(A3_S4_R out_a, A3_S4 b) {
	(out_a[0])[0] += b[0];
	(out_a[0])[1] += b[1];
	(out_a[0])[2] += b[2];
}

FI_ void add_a3s4_fp(A3_S4_R out_a, A3_S4 b) {
	(out_a[0])[0] += b[0] >> 1;
	(out_a[0])[1] += b[1] >> 1;
	(out_a[0])[2] += b[2] >> 1;
}

FI_ void add_v3s4   (V3_S4_R out_a, V3_S4 b) {  add_a3s4   (pcast(A3_S4_R, out_a), pcast(A3_S4, b));  }
FI_ void add_v3s4_fp(V3_S4_R out_a, V3_S4 b) {  add_a3s4_fp(pcast(A3_S4_R, out_a), pcast(A3_S4, b));  }
