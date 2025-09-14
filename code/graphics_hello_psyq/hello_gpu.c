// #include <stdlib.h>
#include "duffle/dsl.h"
#include "duffle/math.h"
#include "duffle/gp.h"
#include "hello_gpu.h"

#include "libgpu.h"
#include "libetc.h"

DoubleBuffer screen_buffer;
S16          active_screen_buffer;

void gp_screen_init_c11(void)
{
	ResetGraph(0);
	SetDispMask(1); // gp_DisplayEnabled

	// Just setting env data, not interacting with console hw.
	// First buffer area
	SetDefDispEnv((DISPENV*)& screen_buffer.display[0], 0, 0,           ScreenRes_X, ScreenRes_Y);
	SetDefDrawEnv((DRAWENV*)& screen_buffer.draw   [0], 0, ScreenRes_Y, ScreenRes_X, ScreenRes_Y);
	// Second buffer area
	SetDefDispEnv((DISPENV*)& screen_buffer.display[1], 0, ScreenRes_Y, ScreenRes_X, ScreenRes_Y);
	SetDefDrawEnv((DRAWENV*)& screen_buffer.draw   [1], 0, 0,           ScreenRes_X, ScreenRes_Y);
	// Set the back/drawing buffer
	screen_buffer.draw[0].enable_auto_clear = true;
	screen_buffer.draw[1].enable_auto_clear = true;
	// Set the background clear color
	screen_buffer.draw[0].initial_bg_color = (RGB8){ .r = 63,  .g = 0,  .b = 127 };
	screen_buffer.draw[1].initial_bg_color = (RGB8){ .r = 127, .g = 63, .b = 0 };
	// Set the current initial buffer
	active_screen_buffer = 0;

	PutDispEnv((DISPENV*)& screen_buffer.display[active_screen_buffer]);

	DRAWENV* wtf = (DRAWENV*)& screen_buffer.draw   [active_screen_buffer];
	PutDrawEnv(wtf);

	// Initialize and setup the GTE geometry offsets
	InitGeom();

	SetGeomOffset(ScreenRes_CenterX, ScreenRes_CenterY);
	SetGeomScreen(ScreenRes_CenterX);
}

void gp_display_frame(void) {
	DrawSync(0);
	VSync(0);
	PutDispEnv((DISPENV*)& screen_buffer.display[active_screen_buffer]);
	PutDrawEnv((DRAWENV*)& screen_buffer.draw   [active_screen_buffer]);
	{
		// TODO: Sort objects in ordering table
	}
	active_screen_buffer = !active_screen_buffer; // Swap current buffer
}

void render(void) {
}

int main(void)
{
	gp_screen_init();
	while (1) 
	{
		render();
		gp_display_frame();
	};
	return 0;
}
