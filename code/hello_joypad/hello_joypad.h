#ifdef INTELLISENSE_DIRECTIVES
#	pragma once
#	include "duffle/dsl.h"
#	include "duffle/math.h"
#	include "duffle/gp.h"
#endif

enum {
	PrimitiveBuff_Len = 4096,
	OrderingTbl_Len   = 2048
};

#define ScreenRes_X 320
#define ScreenRes_Y 240
#define ScreenZ     320
#define ScreenRes_CenterX (ScreenRes_X >> 1)
#define ScreenRes_CenterY (ScreenRes_Y >> 1)

enum {
	fp_one = (1 << 12),
};

#define v3s4_fp_one() v3s4(fp_one, fp_one, fp_one)
