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
#define ScreenRes_CenterX (ScreenRes_X >> 1)
#define ScreenRes_CenterY (ScreenRes_Y >> 1)

extern DoubleBuffer screen_buffer;
extern S16          active_screen_buffer;
