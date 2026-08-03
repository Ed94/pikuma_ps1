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

#ifdef INTELLISENSE_DIRECTIVES
#	include "duffle/pad.h"
#endif

/* ============================================================
 * Raw SIO0 pad subsystem (raw_sio_pad_poll_20260802)
 * ============================================================ */

typedef Struct_(Binds_PadSioStep) {
	PadState* state0;
	PadState* state1;
	U4 sio_base_addr0;
	U4 sio_base_addr1;
};

typedef Struct_(Binds_PadApplyInput) {
	PadState* state;
	V3_S2*    cube_rot;
	V3_S2*    floor_rot;
};

/* Populates smem.pad_sio_init with the two PadState pointers and the
 * KSEG1 SIO0 base. The caller (main()) runs this once at boot before
 * the first tb_emit(pad_sio_init). */
void pad_sio_init_setup(PadSioInit* init, PadState* s0, PadState* s1);
