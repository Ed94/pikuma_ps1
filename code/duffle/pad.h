#ifdef INTELLISENSE_DIRECTIVES
#	pragma once
#	include "dsl.h"
#endif


enum {
	Bit_(Pad_L2,       0),
	Bit_(Pad_R2,       1),
	Bit_(Pad_L1,       2),
	Bit_(Pad_R1,       3),
	Bit_(Pad_Triangle, 4),
	Bit_(Pad_Circle,   5),
	Bit_(Pad_Cross,    6),
	Bit_(Pad_Square,   7),
	Bit_(Pad_Select,   8),
	Bit_(Unused_PadI,  9),
	Bit_(Unused_PadJ, 10),
	Bit_(Pad_Start,   11),
	Bit_(Pad_Up,      12),
	Bit_(Pad_Right,   13),
	Bit_(Pad_Down,    14),
	Bit_(Pad_Left,    15),
};

enum {
	PadId_Offset = 4,

	Pad0 = 0 << PadId_Offset,
	Pad1 = 1 << PadId_Offset,
};

#define pad0_(btn_id) (btn_id << Pad0)
#define pad1_(btn_id) (btn_id << Pad1)

void pad_init(U4 mode) asm("PadInit");
U4   pad_read(U4 id)   asm("PadRead");

