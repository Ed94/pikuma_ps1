#ifdef INTELLISENSE_DIRECTIVES
#	pragma once
#	include "duffle/dsl.h"
#	include "duffle/math.h"
#	include "duffle/gp.h"
#	include "duffle/pad.h"
#endif

enum {
	PrimitiveBuff_Len = 4096,
	OrderingTbl_Len   = 2048
};

enum {
	ScreenRes_X = 320,
	ScreenRes_Y = 240,
	ScreenZ     = 320,
	ScreenRes_CenterX = (ScreenRes_X >> 1),
	ScreenRes_CenterY = (ScreenRes_Y >> 1),
};

enum {
	fp_one = (1 << 12),
};

#define v3s4_fp_one() v3s4(fp_one, fp_one, fp_one)
