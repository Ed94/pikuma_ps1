#include <libetc.h>
#include <libgpu.h>
#include <libgte.h>
#include <stdlib.h>

#define OTSIZE 4096
#define SCREEN_Z 512

typedef struct DB {
    DRAWENV draw;
    DISPENV disp;
    u_long ot[OTSIZE];
    POLY_F4 s[6];
} DB;


int main(void)
{
    DB db[2];
    DB *cdb;

	ResetGraph(0);
    InitGeom();

    SetGraphDebug(0);

    FntLoad(960, 256);
    SetDumpFnt(FntOpen(32, 32, 320, 64, 0, 512));

    SetGeomOffset(320, 240);
    SetGeomScreen(SCREEN_Z);

    SetDefDrawEnv(&db[0].draw, 0, 0, 640, 480);
    SetDefDrawEnv(&db[1].draw, 0, 0, 640, 480);
    SetDefDispEnv(&db[0].disp, 0, 0, 640, 480);
    SetDefDispEnv(&db[1].disp, 0, 0, 640, 480);

	while (1) {
		FntPrint("Code compiled using Psy-Q libraries\n\n");
		FntPrint("converted by psyq-obj-parser\n\n");
		FntPrint("PCSX-Redux project\n\n");
		FntPrint("https://bit.ly/pcsx-redux");

		ClearImage(&cdb->draw.clip, 60, 120, 120);

		DrawSync(0);
		VSync(0);
	}

	return 0;
}
